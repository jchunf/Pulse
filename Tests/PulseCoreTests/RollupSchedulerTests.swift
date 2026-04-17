import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("RollupScheduler — periodic L0→L1→L2→L3 rollups + purge")
struct RollupSchedulerTests {

    private func makeScheduler() throws -> (RollupScheduler, PulseDatabase, FakeClock) {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)
        return (scheduler, db, clock)
    }

    private func appendRawMouseMove(db: PulseDatabase, atMillis ts: Int64) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [ts]
            )
        }
    }

    @Test("first tick runs every job (none have run yet)")
    func firstTickRunsAll() throws {
        let (scheduler, _, clock) = try makeScheduler()
        let ran = try scheduler.tick(now: clock.now)
        #expect(ran == Set(RollupScheduler.Job.allCases))
    }

    @Test("a second tick within the configured interval is a no-op")
    func intervalThrottling() throws {
        let (scheduler, _, clock) = try makeScheduler()
        _ = try scheduler.tick(now: clock.now)
        clock.advance(10) // less than every interval
        let ran = try scheduler.tick(now: clock.now)
        #expect(ran.isEmpty)
    }

    @Test("rawToSecond aggregates raw mouse moves into sec_mouse and clears raw")
    func rawToSecondAggregates() throws {
        let (scheduler, db, clock) = try makeScheduler()
        // Seed three moves all in the same logical "second" (1_700_000_001).
        let baseSecondMs: Int64 = 1_700_000_001 * 1_000
        try appendRawMouseMove(db: db, atMillis: baseSecondMs + 100)
        try appendRawMouseMove(db: db, atMillis: baseSecondMs + 200)
        try appendRawMouseMove(db: db, atMillis: baseSecondMs + 999)

        // Move clock past the bucket so the rollup considers it complete.
        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let secRow: (Int64, Int64)? = try db.queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT ts_second, move_events FROM sec_mouse")
            guard let row else { return nil }
            return ((row[0] as? Int64) ?? -1, (row[1] as? Int64) ?? -1)
        }
        #expect(secRow != nil)
        #expect(secRow?.0 == 1_700_000_001)
        #expect(secRow?.1 == 3)

        let rawRemaining = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_mouse_moves") ?? -1
        }
        #expect(rawRemaining == 0)
    }

    @Test("rawToSecond is idempotent: running twice does not double-count")
    func rawToSecondIdempotent() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let baseSecondMs: Int64 = 1_700_000_001 * 1_000
        try appendRawMouseMove(db: db, atMillis: baseSecondMs + 100)

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let count = try db.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT move_events FROM sec_mouse") ?? -1
        }
        #expect(count == 1)
    }

    @Test("rawToSecond does not touch the partial current second")
    func excludesPartialBucket() throws {
        let (scheduler, db, clock) = try makeScheduler()
        // Append a mouse move IN THE FUTURE second relative to clock.now.
        let nowMs = Int64(clock.now.timeIntervalSince1970 * 1_000)
        try appendRawMouseMove(db: db, atMillis: nowMs + 100) // current second
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        let secCount = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_mouse") ?? -1
        }
        #expect(secCount == 0, "current second should be left for next rollup")
    }

    @Test("purgeExpired deletes raw rows older than the retention cutoff")
    func purgeExpiredRespectsRetention() throws {
        let (scheduler, db, clock) = try makeScheduler()
        // Insert a row dated 30 days ago (well beyond 14-day raw retention).
        let oldMs = Int64((clock.now.timeIntervalSince1970 - 30 * 86_400) * 1_000)
        try appendRawMouseMove(db: db, atMillis: oldMs)
        // And one inside the window.
        let recentMs = Int64((clock.now.timeIntervalSince1970 - 1) * 1_000)
        try appendRawMouseMove(db: db, atMillis: recentMs)

        try scheduler.runOnce(.purgeExpired, now: clock.now)

        let remainingTimes = try db.queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ts FROM raw_mouse_moves")
        }
        #expect(remainingTimes == [recentMs])
    }

    @Test("stamps record the time each job last ran")
    func stampsRecorded() throws {
        let (scheduler, _, clock) = try makeScheduler()
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        #expect(scheduler.stamps.rawToSecond == clock.now)
        #expect(scheduler.stamps.purgeExpired == nil)
    }

    // MARK: - B5 app-usage rollup

    private func insertForegroundSwitch(
        into db: PulseDatabase,
        atMillis ts: Int64,
        bundle: String
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [ts, bundle]
            )
        }
    }

    @Test("foregroundAppToMin attributes interval seconds to each containing minute")
    func foregroundAppToMinBasic() throws {
        let (scheduler, db, clock) = try makeScheduler()
        // Align the fake clock on a minute boundary so expected counts are
        // obvious: clock = 1_700_000_000 (exactly a minute start).
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000

        // Switch to Safari at minute+0s, Xcode at minute+30s.
        try insertForegroundSwitch(into: db, atMillis: baseMs, bundle: "com.apple.Safari")
        try insertForegroundSwitch(into: db, atMillis: baseMs + 30_000, bundle: "com.apple.dt.Xcode")

        // Advance the clock a full minute past the first switch so the
        // minute we're attributing to is "closed" from the scheduler's
        // point of view.
        clock.advance(120)
        try scheduler.runOnce(.foregroundAppToMin, now: clock.now)

        let rows: [(Int64, String, Int64)] = try db.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts_minute, bundle_id, seconds_used FROM min_app ORDER BY ts_minute, bundle_id"
            ).map { row in
                (row["ts_minute"] as Int64, row["bundle_id"] as String, row["seconds_used"] as Int64)
            }
        }
        // First minute: Safari 30s, Xcode 30s. Second minute: Xcode 60s
        // (continuing through the full minute). Total 3 rows.
        #expect(rows.count == 3)
        #expect(rows[0] == (minuteStartSec, "com.apple.Safari", 30))
        #expect(rows[1] == (minuteStartSec, "com.apple.dt.Xcode", 30))
        #expect(rows[2] == (minuteStartSec + 60, "com.apple.dt.Xcode", 60))
    }

    @Test("foregroundAppToMin is idempotent: re-running does not double-count")
    func foregroundAppToMinIdempotent() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000
        try insertForegroundSwitch(into: db, atMillis: baseMs, bundle: "com.apple.Safari")

        clock.advance(120)
        try scheduler.runOnce(.foregroundAppToMin, now: clock.now)
        try scheduler.runOnce(.foregroundAppToMin, now: clock.now)

        let totals: [Int64] = try db.queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT seconds_used FROM min_app")
        }
        // Each minute should reflect a single 60s attribution, not doubled.
        #expect(totals.allSatisfy { $0 == 60 })
    }

    @Test("foregroundAppToMin carries the bundle active before the watermark")
    func foregroundAppToMinCarriesPriorBundle() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000

        // A Safari switch 5 minutes before the clock — this becomes the
        // watermark's "prior bundle" on the first rollup run.
        try insertForegroundSwitch(into: db, atMillis: baseMs - 5 * 60_000, bundle: "com.apple.Safari")
        // Nothing else — Safari has been active for 5 min straight.

        clock.advance(120)
        try scheduler.runOnce(.foregroundAppToMin, now: clock.now)

        let total: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(seconds_used), 0) FROM min_app") ?? 0
        }
        // Clock.now is at minuteStartSec+120 → minuteBucket is
        // minuteStartSec+120 (the start of the current minute). Closed
        // minutes covered: [baseMs - 5min, minuteStart+120ms / 1000 - 120).
        // That's 7 full minutes of Safari at 60s each = 420s.
        #expect(total == 420)
    }

    // MARK: - B6 idle rollup

    private func insertIdleEvent(
        into db: PulseDatabase,
        atMillis ts: Int64,
        entered: Bool
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, NULL)",
                arguments: [ts, entered ? "idle_entered" : "idle_exited"]
            )
        }
    }

    @Test("idleEventsToMin attributes paired idle intervals to minute buckets")
    func idleEventsToMinBasic() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000

        // Idle from minute+10s to minute+50s → 40 seconds in minute 0.
        try insertIdleEvent(into: db, atMillis: baseMs + 10_000, entered: true)
        try insertIdleEvent(into: db, atMillis: baseMs + 50_000, entered: false)

        clock.advance(120)
        try scheduler.runOnce(.idleEventsToMin, now: clock.now)

        let rows: [(Int64, Int64)] = try db.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts_minute, idle_seconds FROM min_idle ORDER BY ts_minute"
            ).map { row in
                (row["ts_minute"] as Int64, row["idle_seconds"] as Int64)
            }
        }
        #expect(rows.count == 1)
        #expect(rows[0] == (minuteStartSec, 40))
    }

    @Test("idleEventsToMin is idempotent: second tick does not double-count")
    func idleEventsToMinIdempotent() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000
        try insertIdleEvent(into: db, atMillis: baseMs + 10_000, entered: true)
        try insertIdleEvent(into: db, atMillis: baseMs + 40_000, entered: false)

        clock.advance(120)
        try scheduler.runOnce(.idleEventsToMin, now: clock.now)
        try scheduler.runOnce(.idleEventsToMin, now: clock.now)

        let total: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(idle_seconds), 0) FROM min_idle") ?? -1
        }
        #expect(total == 30)
    }

    @Test("idleEventsToMin carries an idle state open across the watermark")
    func idleEventsToMinCarriesOpenInterval() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let minuteStartSec: Int64 = 1_700_000_000 - (1_700_000_000 % 60)
        let baseMs: Int64 = minuteStartSec * 1_000

        // Idle entered 2 minutes before the fake clock; no exit.
        try insertIdleEvent(into: db, atMillis: baseMs - 120_000, entered: true)

        clock.advance(120)
        try scheduler.runOnce(.idleEventsToMin, now: clock.now)

        // Clock is at +120s → minuteCutoff = +120. Idle was open from -120
        // through +120 → 4 minutes of idle spanning M-2, M-1, M0, M1.
        let total: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(idle_seconds), 0) FROM min_idle") ?? -1
        }
        #expect(total == 240)
    }

    @Test("minAppToHour aggregates into hour_app and deletes min_app rows")
    func minAppToHourPromotes() throws {
        let (scheduler, db, clock) = try makeScheduler()
        let hourStart: Int64 = 1_700_000_000 - (1_700_000_000 % 3_600)
        try db.queue.write { db in
            // 3 minutes of Safari (120s total) + 1 minute of Xcode (45s).
            try db.execute(sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, 'com.apple.Safari', 40)", arguments: [hourStart])
            try db.execute(sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, 'com.apple.Safari', 40)", arguments: [hourStart + 60])
            try db.execute(sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, 'com.apple.Safari', 40)", arguments: [hourStart + 120])
            try db.execute(sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, 'com.apple.dt.Xcode', 45)", arguments: [hourStart + 180])
        }

        // Advance clock past the hour boundary so the rollup treats the
        // seeded hour as closed.
        clock.advance(3_700)
        try scheduler.runOnce(.minAppToHour, now: clock.now)

        let rows: [(Int64, String, Int64)] = try db.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts_hour, bundle_id, seconds_used FROM hour_app ORDER BY bundle_id"
            ).map { row in
                (row["ts_hour"] as Int64, row["bundle_id"] as String, row["seconds_used"] as Int64)
            }
        }
        #expect(rows.count == 2)
        #expect(rows[0] == (hourStart, "com.apple.Safari", 120))
        #expect(rows[1] == (hourStart, "com.apple.dt.Xcode", 45))

        // min_app rows for the closed hour must be gone.
        let remaining: Int = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM min_app") ?? -1
        }
        #expect(remaining == 0)
    }
}

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
}

import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("MouseTrajectoryQueries — F-04 density read path + B9 rollup binning")
struct MouseTrajectoryQueriesTests {

    // MARK: - Fixtures

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-04-18 17:00 UTC — same anchor Continuity tests use.
    private var referenceEnd: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 18
        components.hour = 17; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    /// Zero-offset reference day (start of UTC 2026-04-18).
    private var referenceDayStartSec: Int64 {
        Int64(utcCalendar.startOfDay(for: referenceEnd).timeIntervalSince1970)
    }

    /// Seed `day_mouse_density` directly. Used by read-side tests to
    /// avoid the overhead of driving the rollup for every case.
    private func seedCell(
        _ db: PulseDatabase,
        day: Int64,
        displayId: UInt32,
        binX: Int,
        binY: Int,
        count: Int64
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO day_mouse_density (day, display_id, bin_x, bin_y, count)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(day, display_id, bin_x, bin_y)
                DO UPDATE SET count = day_mouse_density.count + excluded.count
                """,
                arguments: [day, Int64(displayId), binX, binY, count]
            )
        }
    }

    // MARK: - Read path: mouseDensity

    @Test("empty database returns an empty array")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.isEmpty)
    }

    @Test("single display, single cell — returned with correct shape")
    func singleCell() throws {
        let (store, db) = try makeStore()
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 64, binY: 64, count: 10)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.count == 1)
        #expect(result[0].displayId == 1)
        #expect(result[0].gridSize == MouseTrajectoryGrid.size)
        #expect(result[0].totalCount == 10)
        #expect(result[0].cells == [MouseDensityCell(binX: 64, binY: 64, count: 10)])
    }

    @Test("multi-display results are sorted by total count desc")
    func multiDisplaySortedByTotal() throws {
        let (store, db) = try makeStore()
        // Display 7 is the quieter one.
        try seedCell(db, day: referenceDayStartSec, displayId: 7, binX: 10, binY: 10, count: 3)
        // Display 99 dominates.
        try seedCell(db, day: referenceDayStartSec, displayId: 99, binX: 50, binY: 50, count: 100)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.map(\.displayId) == [99, 7])
        #expect(result.map(\.totalCount) == [100, 3])
    }

    @Test("activity outside the window is excluded")
    func outsideWindow() throws {
        let (store, db) = try makeStore()
        // 30 days in the past — well outside a 7-day window.
        let oldDay = referenceDayStartSec - 30 * 86_400
        try seedCell(db, day: oldDay, displayId: 1, binX: 0, binY: 0, count: 999)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.isEmpty)
    }

    @Test("same cell across days sums into a single total")
    func crossDayCellSummation() throws {
        let (store, db) = try makeStore()
        // Two separate days, same cell, counts should add.
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 10, binY: 20, count: 4)
        try seedCell(db, day: referenceDayStartSec - 86_400, displayId: 1, binX: 10, binY: 20, count: 6)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.count == 1)
        #expect(result[0].totalCount == 10)
        #expect(result[0].cells == [MouseDensityCell(binX: 10, binY: 20, count: 10)])
    }

    @Test("cells per display are ordered (y, x) ascending")
    func cellsSortedForDeterminism() throws {
        let (store, db) = try makeStore()
        // Seed out of order; query result must reorder.
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 5, binY: 2, count: 1)
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 1, binY: 1, count: 1)
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 3, binY: 1, count: 1)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.count == 1)
        #expect(result[0].cells.map { ($0.binY, $0.binX) }.elementsEqual([(1, 1), (1, 3), (2, 5)], by: ==))
    }

    @Test("peakCount reflects the maximum cell count in the histogram")
    func peakCountHelper() throws {
        let (store, db) = try makeStore()
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 1, binY: 1, count: 2)
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 2, binY: 2, count: 99)
        try seedCell(db, day: referenceDayStartSec, displayId: 1, binX: 3, binY: 3, count: 7)

        let result = try store.mouseDensity(
            endingAt: referenceEnd,
            days: 1,
            calendar: utcCalendar
        )
        #expect(result[0].peakCount == 99)
    }

    // MARK: - Read path: latestDisplaySnapshot

    @Test("latestDisplaySnapshot picks the newest row for that display")
    func latestDisplaySnapshotNewest() throws {
        let (store, db) = try makeStore()
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO display_snapshots (ts, display_id, width_px, height_px, dpi, is_primary) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [Int64(1_000), 1, 2560, 1600, 110.0, 1]
            )
            try db.execute(
                sql: "INSERT INTO display_snapshots (ts, display_id, width_px, height_px, dpi, is_primary) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [Int64(2_000), 1, 3456, 2234, 254.0, 1]
            )
            // Noise for another display, should not leak.
            try db.execute(
                sql: "INSERT INTO display_snapshots (ts, display_id, width_px, height_px, dpi, is_primary) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [Int64(3_000), 2, 1920, 1080, 92.0, 0]
            )
        }

        let info = try store.latestDisplaySnapshot(displayId: 1)
        #expect(info?.widthPx == 3456)
        #expect(info?.heightPx == 2234)
        #expect(info?.dpi == 254.0)
        #expect(info?.isPrimary == true)
    }

    @Test("latestDisplaySnapshot returns nil when no snapshot exists")
    func latestDisplaySnapshotMissing() throws {
        let (store, _) = try makeStore()
        #expect(try store.latestDisplaySnapshot(displayId: 42) == nil)
    }

    // MARK: - Write path (B9): rollRawToSecond populates day_mouse_density

    @Test("rollup bins raw moves into day_mouse_density (clamped edges)")
    func rollupBinsIntoDensity() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        // Three points at known positions in the same second, same display.
        // x_norm = 1.0 is the clamp edge (must land in bin 127, not 128).
        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.0, 0.0)",
                arguments: [baseMs]
            )
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [baseMs + 1]
            )
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 1.0, 1.0)",
                arguments: [baseMs + 2]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let cells: [(Int, Int, Int64)] = try db.queue.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: """
                    SELECT bin_x, bin_y, count FROM day_mouse_density
                    WHERE display_id = 1 ORDER BY bin_y, bin_x
                    """
                )
                .map { row in
                    let bx: Int = row["bin_x"]
                    let by: Int = row["bin_y"]
                    let c: Int64 = row["count"]
                    return (bx, by, c)
                }
        }

        // (0, 0) for x=0 y=0; (64, 64) for 0.5/0.5; (127, 127) for the
        // clamped 1.0/1.0 edge. Each appears exactly once.
        #expect(cells.count == 3)
        #expect(cells[0] == (0, 0, 1))
        #expect(cells[1] == (64, 64, 1))
        #expect(cells[2] == (127, 127, 1))
    }

    @Test("rollup accumulates into the same bin when moves repeat")
    func rollupAccumulatesBin() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        // 5 moves that all round into the same (bin_x, bin_y).
        try db.queue.write { db in
            for i in 0..<5 {
                try db.execute(
                    sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.50, 0.50)",
                    arguments: [baseMs + Int64(i)]
                )
            }
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let cnt: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT count FROM day_mouse_density
                WHERE display_id = 1 AND bin_x = 64 AND bin_y = 64
                """) ?? -1
        }
        #expect(cnt == 5)
    }

    @Test("rollup partitions by display_id")
    func rollupPartitionsByDisplay() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [baseMs]
            )
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 2, 0.5, 0.5)",
                arguments: [baseMs + 1]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let rows: [Int64: Int64] = try db.queue.read { db in
            var out: [Int64: Int64] = [:]
            let fetched = try Row.fetchAll(db, sql: "SELECT display_id, count FROM day_mouse_density")
            for row in fetched {
                let d: Int64 = row["display_id"]
                let c: Int64 = row["count"]
                out[d] = c
            }
            return out
        }
        #expect(rows == [1: 1, 2: 1])
    }

    @Test("raw rows are still deleted after density binning")
    func rollupStillDeletesRawRows() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [baseMs]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let rawLeft = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_mouse_moves") ?? -1
        }
        #expect(rawLeft == 0)
    }

    @Test("rollup is idempotent — rerun adds no new density")
    func rollupIdempotentForDensity() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [baseMs]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        // Rerun with no new raw rows — density should stay at 1.
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let cnt: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT count FROM day_mouse_density
                WHERE display_id = 1 AND bin_x = 64 AND bin_y = 64
                """) ?? -1
        }
        #expect(cnt == 1)
    }

    @Test("rollup buckets into local-day using the current timezone")
    func rollupBucketsIntoLocalDay() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [baseMs]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        // Whatever the runner's local timezone is, the stored `day` must
        // equal the start of that local day expressed in UTC epoch
        // seconds. Compute the expected value the same way the rollup does.
        let baseSec = TimeInterval(baseMs) / 1000.0
        let localOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: baseSec)))
        let expectedDay = Int64((floor((baseSec + localOffset) / 86_400.0) * 86_400.0) - localOffset)

        let storedDay: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT day FROM day_mouse_density LIMIT 1") ?? -1
        }
        #expect(storedDay == expectedDay)
    }

    // MARK: - F-16: click density (mouseClickDensity + V7 rollup)

    /// Seed `day_click_density` directly. Mirror of `seedCell` for the
    /// click-density read tests; avoids running the rollup just to
    /// populate a single row.
    private func seedClickCell(
        _ db: PulseDatabase,
        day: Int64,
        displayId: UInt32,
        binX: Int,
        binY: Int,
        count: Int64
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO day_click_density (day, display_id, bin_x, bin_y, count)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(day, display_id, bin_x, bin_y)
                DO UPDATE SET count = day_click_density.count + excluded.count
                """,
                arguments: [day, Int64(displayId), binX, binY, count]
            )
        }
    }

    @Test("mouseClickDensity returns empty on a fresh database")
    func clickDensityEmpty() throws {
        let (store, _) = try makeStore()
        let result = try store.mouseClickDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.isEmpty)
    }

    @Test("mouseClickDensity returns a populated cell with the right shape")
    func clickDensitySingleCell() throws {
        let (store, db) = try makeStore()
        try seedClickCell(db, day: referenceDayStartSec, displayId: 3, binX: 12, binY: 34, count: 7)

        let result = try store.mouseClickDensity(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.count == 1)
        #expect(result[0].displayId == 3)
        #expect(result[0].gridSize == MouseTrajectoryGrid.size)
        #expect(result[0].totalCount == 7)
        #expect(result[0].cells == [MouseDensityCell(binX: 12, binY: 34, count: 7)])
    }

    @Test("rollup bins raw clicks into day_click_density (clamped edges)")
    func rollupBinsClicksIntoDensity() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        // Two clicks: one centred, one at the (1.0, 1.0) clamp edge.
        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button, is_double) VALUES (?, 1, 0.5, 0.5, 0, 0)",
                arguments: [baseMs]
            )
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button, is_double) VALUES (?, 1, 1.0, 1.0, 0, 0)",
                arguments: [baseMs + 1]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let cells: [(Int, Int, Int64)] = try db.queue.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: "SELECT bin_x, bin_y, count FROM day_click_density WHERE display_id = 1 ORDER BY bin_y, bin_x"
                )
                .map { row in
                    let bx: Int = row["bin_x"]
                    let by: Int = row["bin_y"]
                    let c: Int64 = row["count"]
                    return (bx, by, c)
                }
        }
        // Centre + clamp-edge cell, each one click.
        #expect(cells.count == 2)
        #expect(cells[0] == (64, 64, 1))
        #expect(cells[1] == (127, 127, 1))
    }

    @Test("click rollup is idempotent — rerun adds no new density")
    func clickRollupIdempotent() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_776_000_000))
        let db = try PulseDatabase.inMemory()
        let scheduler = RollupScheduler(database: db, clock: clock)

        let baseMs = Int64(clock.now.timeIntervalSince1970) * 1_000 + 100
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button, is_double) VALUES (?, 1, 0.5, 0.5, 0, 0)",
                arguments: [baseMs]
            )
        }

        clock.advance(5)
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        // Rerun: raw row is gone, density should stay at 1.
        try scheduler.runOnce(.rawToSecond, now: clock.now)

        let cnt: Int64 = try db.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT count FROM day_click_density
                WHERE display_id = 1 AND bin_x = 64 AND bin_y = 64
                """) ?? -1
        }
        #expect(cnt == 1)
    }
}

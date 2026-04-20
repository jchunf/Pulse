import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("RangePurge — F-47 time-range data deletion")
struct RangePurgeTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    // Fixed instants so DST and host timezone don't perturb anything.
    private let rangeStart = Date(timeIntervalSince1970: 1_776_614_400) // 2026-04-19 12:00 UTC
    private let rangeEnd   = Date(timeIntervalSince1970: 1_776_618_000) // 2026-04-19 13:00 UTC
    private let beforeRange = Date(timeIntervalSince1970: 1_776_610_800) // 11:00 UTC
    private let afterRange  = Date(timeIntervalSince1970: 1_776_621_600) // 14:00 UTC
    private let insideRange = Date(timeIntervalSince1970: 1_776_616_200) // 12:30 UTC

    /// Audit is 14:00 so it stays outside the purged range; the
    /// production code defaults to `Date()` which is also outside.
    private var auditAt: Date { afterRange }

    // MARK: - Seeders

    private func seedMillisecondTables(_ db: PulseDatabase, at instant: Date) throws {
        let ms = Int64(instant.timeIntervalSince1970 * 1_000)
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                arguments: [ms]
            )
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button) VALUES (?, 1, 0.5, 0.5, 'left')",
                arguments: [ms]
            )
            try db.execute(
                sql: "INSERT INTO raw_key_events (ts, key_code) VALUES (?, NULL)",
                arguments: [ms]
            )
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', 'com.test.App')",
                arguments: [ms]
            )
            try db.execute(
                sql: """
                INSERT INTO display_snapshots (ts, display_id, width_px, height_px, dpi)
                VALUES (?, 1, 1920, 1080, 220.0)
                """,
                arguments: [ms]
            )
        }
    }

    private func seedBucketTables(_ db: PulseDatabase, at instant: Date) throws {
        let sec = Int64(instant.timeIntervalSince1970)
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO sec_mouse (ts_second, move_events, click_events, scroll_ticks, distance_mm) VALUES (?, 1, 0, 0, 10.0)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO sec_key (ts_second, press_count) VALUES (?, 1)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO sec_activity (ts_second, bundle_id) VALUES (?, 'com.test.App')",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO min_mouse (ts_minute, move_events, click_events, scroll_ticks, distance_mm) VALUES (?, 10, 2, 0, 100.0)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO min_key (ts_minute, press_count) VALUES (?, 50)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, 'com.test.App', 60)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO min_switches (ts_minute, app_switch_count) VALUES (?, 3)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO min_idle (ts_minute, idle_seconds) VALUES (?, 5)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO hour_app (ts_hour, bundle_id, seconds_used) VALUES (?, 'com.test.App', 3600)",
                arguments: [sec]
            )
            try db.execute(
                sql: "INSERT INTO hour_summary (ts_hour, key_press_total, mouse_click_total, idle_seconds) VALUES (?, 500, 20, 60)",
                arguments: [sec]
            )
        }
    }

    private func rowCount(_ db: PulseDatabase, table: String) throws -> Int {
        try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - Empty database

    @Test("empty database — no-op returns zero deleted + audit row lands")
    func emptyDatabase() throws {
        let (store, db) = try makeStore()
        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        #expect(result.deletedRowCount == 0)
        #expect(result.rangeStart == rangeStart)
        #expect(result.rangeEnd == rangeEnd)
        // Audit event is the only row in system_events now.
        #expect(try rowCount(db, table: "system_events") == 1)
    }

    // MARK: - In-range deletion

    @Test("in-range rows in every data table are deleted")
    func inRangeDeleted() throws {
        let (store, db) = try makeStore()
        try seedMillisecondTables(db, at: insideRange)
        try seedBucketTables(db, at: insideRange)

        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        // 5 ms tables × 1 row + 10 bucket tables × 1 row = 15 deletes.
        #expect(result.deletedRowCount == 15)

        let tables = [
            "raw_mouse_moves", "raw_mouse_clicks", "raw_key_events",
            "display_snapshots",
            "sec_mouse", "sec_key", "sec_activity",
            "min_mouse", "min_key", "min_app", "min_switches", "min_idle",
            "hour_app", "hour_summary"
        ]
        for table in tables {
            #expect(try rowCount(db, table: table) == 0)
        }
        // system_events was seeded with 1 row + 1 audit = 1 row now
        // (the seeded foreground_app row was deleted; the audit row
        // at auditAt lands after the purge).
        #expect(try rowCount(db, table: "system_events") == 1)
    }

    // MARK: - Out-of-range preservation

    @Test("rows before and after the range are preserved")
    func outOfRangePreserved() throws {
        let (store, db) = try makeStore()
        try seedMillisecondTables(db, at: beforeRange)
        try seedMillisecondTables(db, at: afterRange)
        try seedBucketTables(db, at: beforeRange)
        try seedBucketTables(db, at: afterRange)

        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        #expect(result.deletedRowCount == 0)

        // Every seeded table has 2 rows (before + after). system_events
        // also has 2 seeded rows + 1 audit = 3 now.
        let twoRowTables = [
            "raw_mouse_moves", "raw_mouse_clicks", "raw_key_events",
            "display_snapshots",
            "sec_mouse", "sec_key", "sec_activity",
            "min_mouse", "min_key", "min_app", "min_switches", "min_idle",
            "hour_app", "hour_summary"
        ]
        for table in twoRowTables {
            #expect(try rowCount(db, table: table) == 2)
        }
        #expect(try rowCount(db, table: "system_events") == 3)
    }

    @Test("mixed seed — only in-range rows are removed")
    func mixedSeed() throws {
        let (store, db) = try makeStore()
        try seedMillisecondTables(db, at: beforeRange)
        try seedMillisecondTables(db, at: insideRange)
        try seedMillisecondTables(db, at: afterRange)

        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        // 5 ms tables × 1 in-range row each.
        #expect(result.deletedRowCount == 5)

        let tables = ["raw_mouse_moves", "raw_mouse_clicks", "raw_key_events", "display_snapshots"]
        for table in tables {
            #expect(try rowCount(db, table: table) == 2) // before + after
        }
        // system_events was seeded 3 times; 1 deleted, 2 preserved,
        // +1 audit row = 3.
        #expect(try rowCount(db, table: "system_events") == 3)
    }

    // MARK: - Audit row

    @Test("audit row is inserted at auditedAt with a data_purged category and ms-range payload")
    func auditRow() throws {
        let (store, db) = try makeStore()
        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        _ = result
        let expectedMs = Int64(auditAt.timeIntervalSince1970 * 1_000)
        let startMs = Int64(rangeStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(rangeEnd.timeIntervalSince1970 * 1_000)
        try db.queue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT ts, category, payload FROM system_events
                WHERE category = 'data_purged'
                """)
            let fetchedTs: Int64? = row?["ts"]
            let fetchedCategory: String? = row?["category"]
            let fetchedPayload: String? = row?["payload"]
            #expect(fetchedTs == expectedMs)
            #expect(fetchedCategory == "data_purged")
            #expect(fetchedPayload == "\(startMs)-\(endMs)")
        }
    }

    // MARK: - Watermarks untouched

    @Test("rollup_watermarks are not modified by purgeRange")
    func watermarksUntouched() throws {
        let (store, db) = try makeStore()
        // Seed a watermark row whose last_processed_ms falls inside the
        // purge window. It must survive the purge — watermarks track
        // processing progress, not stored user data.
        let watermarkMs = Int64(insideRange.timeIntervalSince1970 * 1_000)
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO rollup_watermarks (job, last_processed_ms)
                VALUES ('foreground_app_to_min', ?)
                """,
                arguments: [watermarkMs]
            )
        }
        _ = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        let after = try db.queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT last_processed_ms FROM rollup_watermarks WHERE job = 'foreground_app_to_min'"
            )
        }
        #expect(after == watermarkMs)
    }

    // MARK: - Exclusive end boundary

    @Test("end is exclusive — a row exactly at `end` is preserved")
    func endExclusive() throws {
        let (store, db) = try makeStore()
        // Insert a row at exactly rangeEnd — it should survive.
        try seedMillisecondTables(db, at: rangeEnd)
        let result = try store.purgeRange(
            start: rangeStart,
            end: rangeEnd,
            auditedAt: auditAt
        )
        #expect(result.deletedRowCount == 0)
        #expect(try rowCount(db, table: "raw_mouse_moves") == 1)
    }
}

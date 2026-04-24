import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("LifetimeMileageQueries — all-time cursor distance (F-25)")
struct LifetimeMileageQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insertHourSummary(
        into db: PulseDatabase,
        hourStart: Int64,
        distanceMm: Double
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 0, ?, 0, 0, 0)
                """,
                arguments: [hourStart, distanceMm]
            )
        }
    }

    @Test("empty DB returns zero")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        #expect(try store.lifetimeMouseDistanceMillimeters() == 0)
    }

    @Test("sums mouse_distance_mm across every hour_summary row")
    func sumsAllHours() throws {
        let (store, db) = try makeStore()
        try insertHourSummary(into: db, hourStart: 1_700_000_000, distanceMm: 123.4)
        try insertHourSummary(into: db, hourStart: 1_700_003_600, distanceMm: 456.6)
        try insertHourSummary(into: db, hourStart: 1_700_086_400, distanceMm: 1_000.0)
        let total = try store.lifetimeMouseDistanceMillimeters()
        #expect(abs(total - 1_580.0) < 0.001)
    }
}

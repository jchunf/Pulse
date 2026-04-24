import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("KeyCodeQueries — 7-day distribution (F-08)")
struct KeyCodeQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insert(into db: PulseDatabase, day: Int64, keyCode: Int64, count: Int64) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO day_key_codes (day, key_code, count) VALUES (?, ?, ?)",
                arguments: [day, keyCode, count]
            )
        }
    }

    @Test("empty DB returns empty distribution")
    func emptyDB() throws {
        let (store, _) = try makeStore()
        let rows = try store.keyCodeDistribution(
            endingAt: Date(timeIntervalSince1970: 1_700_000_000),
            days: 7,
            calendar: .utc
        )
        #expect(rows.isEmpty)
    }

    @Test("sums per-keycode counts across the N-day window")
    func sumsAcrossDays() throws {
        let (store, db) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_086_400)  // ~day 19676
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayStartSec = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        // today: keyCode 0 (A) → 10, 1 (S) → 5
        try insert(into: db, day: dayStartSec, keyCode: 0, count: 10)
        try insert(into: db, day: dayStartSec, keyCode: 1, count: 5)
        // yesterday: keyCode 0 → 7
        try insert(into: db, day: dayStartSec - 86_400, keyCode: 0, count: 7)
        // 8 days ago: OUTSIDE 7-day window → ignored
        try insert(into: db, day: dayStartSec - 86_400 * 7, keyCode: 0, count: 999)

        let rows = try store.keyCodeDistribution(endingAt: now, days: 7, calendar: calendar)
        #expect(rows.count == 2)
        #expect(rows[0].keyCode == 0)
        #expect(rows[0].count == 17)
        #expect(rows[1].keyCode == 1)
        #expect(rows[1].count == 5)
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("EventStore.buildExportBundle — user-facing JSON export")
struct DataExportTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test("bundle carries N days of trend points oldest → newest")
    func bundleHasTrendRange() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let endingAt = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 4, day: 17, hour: 15
        ))!
        let endDay = calendar.startOfDay(for: endingAt)

        // Non-zero data in one day of the range so the trend carries data
        // (other days zero-pad automatically).
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 100, 500, 20, 60, 3)
                """, arguments: [Int64(endDay.addingTimeInterval(10 * 3600).timeIntervalSince1970)])
        }

        let bundle = try store.buildExportBundle(
            endingAt: endingAt,
            days: 7,
            calendar: calendar
        )
        #expect(bundle.schemaVersion == 1)
        #expect(bundle.dailyTrend.count == 7)
        #expect(bundle.dailyTrend.first?.day ==
                calendar.date(byAdding: .day, value: -6, to: endDay))
        #expect(bundle.dailyTrend.last?.day == endDay)
    }

    @Test("bundle today totals reflect live summary")
    func bundleTodayTotals() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let endingAt = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 4, day: 17, hour: 12
        ))!
        let endDay = calendar.startOfDay(for: endingAt)

        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 300, 1500.5, 45, 120, 8)
                """, arguments: [Int64(endDay.addingTimeInterval(9 * 3600).timeIntervalSince1970)])
        }

        let bundle = try store.buildExportBundle(
            endingAt: endingAt,
            days: 7,
            calendar: calendar
        )
        #expect(bundle.today.keyPresses == 300)
        #expect(bundle.today.mouseClicks == 45)
        #expect(bundle.today.scrollTicks == 8)
        #expect(bundle.today.mouseDistanceMillimeters == 1500.5)
        #expect(bundle.today.idleSeconds == 120)
    }

    @Test("bundle round-trips through JSONEncoder / JSONDecoder")
    func bundleCodableRoundtrip() throws {
        let (store, _) = try makeStore()
        let bundle = try store.buildExportBundle(days: 7)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExportBundle.self, from: data)
        #expect(decoded == bundle)
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ActivityWeightQueries — F-42 daily active-hours curve")
struct ActivityWeightQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-04-18 12:00 UTC.
    private var endingAt: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 18; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func insertHour(into db: PulseDatabase, day: Date, hour: Int, activeSeconds: Int) throws {
        let dayStart = utcCalendar.startOfDay(for: day)
        let ts = Int64(dayStart.timeIntervalSince1970) + Int64(hour) * 3600
        let idle = max(0, 3600 - activeSeconds)
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds)
                VALUES (?, 0, 0, 0, ?)
                """, arguments: [ts, idle])
        }
    }

    @Test("empty database returns one zero-row per day in the window")
    func empty() throws {
        let (store, _) = try makeStore()
        let result = try store.activityWeight(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(result.count == 7)
        #expect(result.allSatisfy { $0.activeHours == 0 })
        // Chronologically ascending.
        for i in 1..<result.count {
            #expect(result[i].day > result[i - 1].day)
        }
    }

    @Test("a single full hour reads back as 1 hour active")
    func singleHour() throws {
        let (store, db) = try makeStore()
        try insertHour(into: db, day: endingAt, hour: 10, activeSeconds: 3600)
        let result = try store.activityWeight(endingAt: endingAt, days: 7, calendar: utcCalendar)
        let endDayBucket = result.first { utcCalendar.isDate($0.day, inSameDayAs: endingAt) }
        #expect(endDayBucket?.activeHours == 1.0)
    }

    @Test("multiple hours sum into the day's total")
    func summedHours() throws {
        let (store, db) = try makeStore()
        // 1.5 + 1.0 + 0.5 = 3.0 hours of activity on day 0.
        try insertHour(into: db, day: endingAt, hour: 9,  activeSeconds: 5400)  // 1.5h
        try insertHour(into: db, day: endingAt, hour: 10, activeSeconds: 3600)  // 1.0h
        try insertHour(into: db, day: endingAt, hour: 11, activeSeconds: 1800)  // 0.5h

        let result = try store.activityWeight(endingAt: endingAt, days: 7, calendar: utcCalendar)
        let endDayBucket = result.first { utcCalendar.isDate($0.day, inSameDayAs: endingAt) }
        #expect(endDayBucket?.activeHours == 3.0)
    }

    @Test("days with no rows show as zero, between days with activity")
    func gapsRenderAsZero() throws {
        let (store, db) = try makeStore()
        // Activity only on day -3 and day 0.
        let day3back = utcCalendar.date(byAdding: .day, value: -3, to: endingAt)!
        try insertHour(into: db, day: day3back, hour: 10, activeSeconds: 3600)
        try insertHour(into: db, day: endingAt, hour: 14, activeSeconds: 1800)

        let result = try store.activityWeight(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(result.count == 7)
        let nonZero = result.filter { $0.activeHours > 0 }
        #expect(nonZero.count == 2)
        // Active values: 1h on day -3, 0.5h on day 0
        #expect(nonZero[0].activeHours == 1.0)
        #expect(nonZero[1].activeHours == 0.5)
    }

    @Test("activity outside the window is excluded")
    func windowed() throws {
        let (store, db) = try makeStore()
        let day40back = utcCalendar.date(byAdding: .day, value: -40, to: endingAt)!
        try insertHour(into: db, day: day40back, hour: 10, activeSeconds: 3600)
        let result = try store.activityWeight(endingAt: endingAt, days: 30, calendar: utcCalendar)
        #expect(result.count == 30)
        #expect(result.allSatisfy { $0.activeHours == 0 })
    }

    @Test("idle_seconds clamped — degenerate row > 3600 doesn't go negative")
    func idleClamped() throws {
        let (store, db) = try makeStore()
        // A row claiming 7200 idle seconds (twice the hour) — should
        // still produce 0 active, never go negative.
        let dayStart = utcCalendar.startOfDay(for: endingAt)
        let ts = Int64(dayStart.timeIntervalSince1970) + Int64(10) * 3600
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds)
                VALUES (?, 0, 0, 0, ?)
                """, arguments: [ts, 7200])
        }
        let result = try store.activityWeight(endingAt: endingAt, days: 1, calendar: utcCalendar)
        #expect(result.count == 1)
        #expect(result[0].activeHours == 0)
    }
}

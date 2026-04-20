import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("LidQueries — F-27 lid-open counts")
struct LidQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var referenceNow: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 18
        components.hour = 17; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    private func insertLidEvent(
        _ db: PulseDatabase,
        category: String,
        at instant: Date
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, NULL)",
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000), category]
            )
        }
    }

    // MARK: - dailyLidOpens

    @Test("empty database — today is zero")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let count = try store.dailyLidOpens(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(count == 0)
    }

    @Test("counts only lid_opened rows, ignores lid_closed")
    func onlyCountsOpens() throws {
        let (store, db) = try makeStore()
        let day = utcCalendar.startOfDay(for: referenceNow)
        for hour in [9, 12, 15] {
            let at = utcCalendar.date(byAdding: .hour, value: hour, to: day)!
            try insertLidEvent(db, category: "lid_opened", at: at)
        }
        for hour in [11, 14, 16] {
            let at = utcCalendar.date(byAdding: .hour, value: hour, to: day)!
            try insertLidEvent(db, category: "lid_closed", at: at)
        }
        let count = try store.dailyLidOpens(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(count == 3)
    }

    @Test("caps at capUntil — future events in the same day are excluded")
    func capUntilExcludesFuture() throws {
        let (store, db) = try makeStore()
        let day = utcCalendar.startOfDay(for: referenceNow)
        for hour in [9, 12, 18, 20] {
            let at = utcCalendar.date(byAdding: .hour, value: hour, to: day)!
            try insertLidEvent(db, category: "lid_opened", at: at)
        }
        // capUntil is 17:00 — 18:00 / 20:00 must not count.
        let count = try store.dailyLidOpens(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(count == 2) // only 09 and 12
    }

    @Test("ignores events outside the target day")
    func scopedToDay() throws {
        let (store, db) = try makeStore()
        let today = utcCalendar.startOfDay(for: referenceNow)
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: today)!
        try insertLidEvent(db, category: "lid_opened", at: yesterday.addingTimeInterval(3_600 * 10))
        try insertLidEvent(db, category: "lid_opened", at: today.addingTimeInterval(3_600 * 10))
        try insertLidEvent(db, category: "lid_opened", at: today.addingTimeInterval(3_600 * 14))
        let count = try store.dailyLidOpens(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(count == 2)
    }

    // MARK: - lidOpensTrend

    @Test("trend — empty database returns zero-padded array of requested length")
    func trendEmpty() throws {
        let (store, _) = try makeStore()
        let trend = try store.lidOpensTrend(
            endingAt: referenceNow,
            days: 7,
            calendar: utcCalendar
        )
        #expect(trend == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test("trend — attributes events to the right day, oldest → newest")
    func trendSpread() throws {
        let (store, db) = try makeStore()
        let today = utcCalendar.startOfDay(for: referenceNow)
        // today: 3 opens; yesterday: 1; 6 days ago: 2.
        let counts: [Int: Int] = [0: 3, 1: 1, 6: 2]
        for (offset, n) in counts {
            let day = utcCalendar.date(byAdding: .day, value: -offset, to: today)!
            for i in 0..<n {
                let at = day.addingTimeInterval(Double(3_600 * (9 + i)))
                try insertLidEvent(db, category: "lid_opened", at: at)
            }
        }
        let trend = try store.lidOpensTrend(
            endingAt: referenceNow,
            days: 7,
            calendar: utcCalendar
        )
        // Oldest (6d ago) → newest (today): [2, 0, 0, 0, 0, 1, 3]
        #expect(trend == [2, 0, 0, 0, 0, 1, 3])
    }

    @Test("trend — ignores events outside the window")
    func trendOutsideWindow() throws {
        let (store, db) = try makeStore()
        let today = utcCalendar.startOfDay(for: referenceNow)
        let tenDaysAgo = utcCalendar.date(byAdding: .day, value: -10, to: today)!
        try insertLidEvent(db, category: "lid_opened", at: tenDaysAgo.addingTimeInterval(3_600 * 10))
        try insertLidEvent(db, category: "lid_opened", at: today.addingTimeInterval(3_600 * 10))
        let trend = try store.lidOpensTrend(
            endingAt: referenceNow,
            days: 7,
            calendar: utcCalendar
        )
        #expect(trend == [0, 0, 0, 0, 0, 0, 1])
    }

    @Test("trend — lid_closed rows are ignored, only opens counted")
    func trendIgnoresCloses() throws {
        let (store, db) = try makeStore()
        let today = utcCalendar.startOfDay(for: referenceNow)
        try insertLidEvent(db, category: "lid_opened", at: today.addingTimeInterval(3_600 * 9))
        try insertLidEvent(db, category: "lid_closed", at: today.addingTimeInterval(3_600 * 10))
        try insertLidEvent(db, category: "lid_closed", at: today.addingTimeInterval(3_600 * 11))
        let trend = try store.lidOpensTrend(
            endingAt: referenceNow,
            days: 1,
            calendar: utcCalendar
        )
        #expect(trend == [1])
    }
}

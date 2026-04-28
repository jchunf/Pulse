import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("FocusQueries — F-37 Focus / DND interval aggregation")
struct FocusQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-04-18 12:00 UTC — `capUntil` is noon, so `today`
    /// has 12 hours elapsed when querying.
    private var noon: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 18; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func insertFocusEvent(
        into db: PulseDatabase,
        ts: Date,
        category: String,
        payload: String? = nil
    ) throws {
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO system_events (ts, category, payload) VALUES (?, ?, ?)
                """, arguments: [Int64(ts.timeIntervalSince1970 * 1_000), category, payload])
        }
    }

    @Test("empty database — 0 seconds")
    func empty() throws {
        let (store, _) = try makeStore()
        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 0)
        let frac = try store.focusFractionToday(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(frac == 0)
    }

    @Test("single complete in-day interval — sums correctly")
    func basicInterval() throws {
        let (store, db) = try makeStore()
        // Focus on at 09:00, off at 11:00 (UTC) → 2 hours = 7200 seconds.
        let on  = utcCalendar.date(byAdding: .hour, value: 9,  to: utcCalendar.startOfDay(for: noon))!
        let off = utcCalendar.date(byAdding: .hour, value: 11, to: utcCalendar.startOfDay(for: noon))!
        try insertFocusEvent(into: db, ts: on,  category: "focus_on", payload: "Work")
        try insertFocusEvent(into: db, ts: off, category: "focus_off")

        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 7200)
        let frac = try store.focusFractionToday(on: noon, capUntil: noon, calendar: utcCalendar)
        // 2 hours / 12 hours elapsed = 1/6.
        #expect(abs(frac - (1.0 / 6.0)) < 0.0001)
    }

    @Test("multiple intervals — sum")
    func multipleIntervals() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // 09:00–10:00 (1h) and 10:30–11:00 (30m) = 5400 seconds.
        try insertFocusEvent(into: db, ts: utcCalendar.date(byAdding: .hour, value: 9,  to: dayStart)!, category: "focus_on")
        try insertFocusEvent(into: db, ts: utcCalendar.date(byAdding: .hour, value: 10, to: dayStart)!, category: "focus_off")
        try insertFocusEvent(into: db, ts: utcCalendar.date(byAdding: .minute, value: 10 * 60 + 30, to: dayStart)!, category: "focus_on")
        try insertFocusEvent(into: db, ts: utcCalendar.date(byAdding: .hour, value: 11, to: dayStart)!, category: "focus_off")

        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 3600 + 1800)
    }

    @Test("focus_on with no closing focus_off clamps at capUntil")
    func openIntervalClamps() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // Focus turned on at 11:00; no off event. capUntil = noon.
        // Expect 1 hour = 3600 seconds.
        try insertFocusEvent(into: db, ts: utcCalendar.date(byAdding: .hour, value: 11, to: dayStart)!, category: "focus_on", payload: "Personal")

        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 3600)
    }

    @Test("focus_on from yesterday evening counts toward today's seconds")
    func crossDayInterval() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // 23:50 yesterday: focus on. 00:30 today: focus off.
        // Today's window contributes 30 minutes = 1800 seconds.
        let yesterdayEvening = dayStart.addingTimeInterval(-10 * 60)  // 23:50 yesterday UTC
        let earlyToday = dayStart.addingTimeInterval(30 * 60)         // 00:30 today UTC
        try insertFocusEvent(into: db, ts: yesterdayEvening, category: "focus_on")
        try insertFocusEvent(into: db, ts: earlyToday, category: "focus_off")

        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 1800)
    }

    @Test("interval entirely before the day is excluded")
    func priorDayIntervalExcluded() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // Yesterday 10:00–11:00, fully before today.
        try insertFocusEvent(into: db, ts: dayStart.addingTimeInterval(-14 * 3600), category: "focus_on")
        try insertFocusEvent(into: db, ts: dayStart.addingTimeInterval(-13 * 3600), category: "focus_off")

        let secs = try store.dailyFocusSeconds(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(secs == 0)
    }

    @Test("focusFractionToday returns 0 when capUntil == dayStart (no time elapsed)")
    func zeroElapsedWindow() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        try insertFocusEvent(into: db, ts: dayStart.addingTimeInterval(60), category: "focus_on")
        let frac = try store.focusFractionToday(on: dayStart, capUntil: dayStart, calendar: utcCalendar)
        #expect(frac == 0)
    }
}

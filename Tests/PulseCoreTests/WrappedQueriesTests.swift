import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("WrappedQueries — F-24 year-to-date snapshot")
struct WrappedQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func insertHour(
        into db: PulseDatabase,
        date: Date,
        keys: Int,
        clicks: Int,
        distanceMm: Double = 0,
        scrolls: Int = 0,
        idleSeconds: Int = 0
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [Int64(date.timeIntervalSince1970), keys, distanceMm, clicks, idleSeconds, scrolls]
            )
        }
    }

    private func insertSwitch(into db: PulseDatabase, ts: Date, bundle: String) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [Int64(ts.timeIntervalSince1970 * 1_000), bundle]
            )
        }
    }

    @Test("empty store — zeros across the board, no busiest day")
    func emptyStoreReadsAsZero() throws {
        let (store, _) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.daysActive == 0)
        #expect(snap.firstActiveAt == nil)
        #expect(snap.totalKeyPresses == 0)
        #expect(snap.totalMouseClicks == 0)
        #expect(snap.totalMouseDistanceMillimeters == 0)
        #expect(snap.totalScrollTicks == 0)
        #expect(snap.topApps.isEmpty)
        #expect(snap.busiestDay == nil)
        #expect(snap.mostActiveHourOfDay == nil)
        #expect(snap.distinctActiveHoursOfDay == 0)
        #expect(snap.totalAppSwitches == 0)
    }

    @Test("totals sum across hour_summary rows in the year window")
    func totalsSum() throws {
        let (store, db) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        // Three rolled hours in the year.
        try insertHour(into: db, date: date(year: 2026, month: 1, day: 5, hour: 9),  keys: 100, clicks: 20, distanceMm: 1_000, scrolls: 5)
        try insertHour(into: db, date: date(year: 2026, month: 2, day: 10, hour: 14), keys: 250, clicks: 50, distanceMm: 2_500, scrolls: 12)
        try insertHour(into: db, date: date(year: 2026, month: 3, day: 18, hour: 22), keys: 80,  clicks: 10, distanceMm: 500,   scrolls: 3)
        // One hour from PRIOR year — must NOT be counted.
        try insertHour(into: db, date: date(year: 2025, month: 12, day: 31, hour: 23), keys: 999, clicks: 999, distanceMm: 99_999, scrolls: 99)

        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.totalKeyPresses == 430)
        #expect(snap.totalMouseClicks == 80)
        #expect(snap.totalMouseDistanceMillimeters == 4_000)
        #expect(snap.totalScrollTicks == 20)
        #expect(snap.daysActive == 3)
        #expect(snap.distinctActiveHoursOfDay == 3)  // 9, 14, 22
        #expect(snap.firstActiveAt == date(year: 2026, month: 1, day: 5, hour: 9))
    }

    @Test("busiest day picks the highest (key + click) sum")
    func busiestDay() throws {
        let (store, db) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        // Day A — total 30 (keys 20 + clicks 10).
        try insertHour(into: db, date: date(year: 2026, month: 1, day: 5, hour: 9), keys: 20, clicks: 10)
        // Day B — total 100 (keys 70 + clicks 30, in two separate hours).
        try insertHour(into: db, date: date(year: 2026, month: 2, day: 1, hour: 9),  keys: 50, clicks: 20)
        try insertHour(into: db, date: date(year: 2026, month: 2, day: 1, hour: 14), keys: 20, clicks: 10)
        // Day C — total 60.
        try insertHour(into: db, date: date(year: 2026, month: 3, day: 12, hour: 10), keys: 40, clicks: 20)

        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.busiestDay?.day == date(year: 2026, month: 2, day: 1))
        #expect(snap.busiestDay?.totalEvents == 100)
    }

    @Test("most-active hour-of-day across the year")
    func mostActiveHour() throws {
        let (store, db) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        // Hour 9: total 50 across two rolled days
        try insertHour(into: db, date: date(year: 2026, month: 1, day: 5, hour: 9), keys: 20, clicks: 5)
        try insertHour(into: db, date: date(year: 2026, month: 2, day: 1, hour: 9), keys: 20, clicks: 5)
        // Hour 14: total 100 in one rolled day
        try insertHour(into: db, date: date(year: 2026, month: 1, day: 5, hour: 14), keys: 80, clicks: 20)
        // Hour 22: total 10
        try insertHour(into: db, date: date(year: 2026, month: 3, day: 1, hour: 22), keys: 5, clicks: 5)

        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.mostActiveHourOfDay == 14)
        #expect(snap.distinctActiveHoursOfDay == 3)  // hours 9, 14, 22
    }

    @Test("app switches counted from system_events, year-windowed")
    func appSwitchesYearWindowed() throws {
        let (store, db) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        // Two switches before the year: must NOT count.
        try insertSwitch(into: db, ts: date(year: 2025, month: 12, day: 30), bundle: "com.example.A")
        try insertSwitch(into: db, ts: date(year: 2025, month: 12, day: 31), bundle: "com.example.B")
        // Three switches in the year.
        try insertSwitch(into: db, ts: date(year: 2026, month: 1, day: 5),  bundle: "com.example.A")
        try insertSwitch(into: db, ts: date(year: 2026, month: 2, day: 10), bundle: "com.example.B")
        try insertSwitch(into: db, ts: date(year: 2026, month: 3, day: 18), bundle: "com.example.A")

        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.totalAppSwitches == 3)
    }

    @Test("capUntil clamps the year window")
    func capUntilClamps() throws {
        let (store, db) = try makeStore()
        let yearStart = date(year: 2026, month: 1, day: 1)
        // Hour BEFORE cap — counts.
        try insertHour(into: db, date: date(year: 2026, month: 1, day: 5, hour: 9), keys: 100, clicks: 20)
        // Hour AFTER cap — must NOT count.
        try insertHour(into: db, date: date(year: 2026, month: 6, day: 1, hour: 9), keys: 999, clicks: 999)

        let snap = try store.yearWrappedSnapshot(
            yearStart: yearStart,
            capUntil: date(year: 2026, month: 4, day: 29),
            calendar: utcCalendar
        )
        #expect(snap.totalKeyPresses == 100)
        #expect(snap.totalMouseClicks == 20)
        #expect(snap.daysActive == 1)
    }
}

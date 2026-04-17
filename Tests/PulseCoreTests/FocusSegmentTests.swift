import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("EventStore.longestFocusSegment — deep-focus derivation (A16)")
struct FocusSegmentTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    /// UTC day so minute / hour math is deterministic on every runner.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func insertSwitch(into db: PulseDatabase, at instant: Date, bundle: String) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000), bundle]
            )
        }
    }

    private func insertIdleMinute(
        into db: PulseDatabase,
        minuteStart: Date,
        idleSeconds: Int
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_idle (ts_minute, idle_seconds) VALUES (?, ?)",
                arguments: [Int64(minuteStart.timeIntervalSince1970), idleSeconds]
            )
        }
    }

    @Test("single long run with no idle rows yields a full segment")
    func basicSegment() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        let switchAt = calendar.date(byAdding: .hour, value: 9, to: day)!
        try insertSwitch(into: db, at: switchAt, bundle: "com.apple.dt.Xcode")

        // Query at 11:00 → interval is 9:00–11:00, 120 minutes, no idle.
        let now = calendar.date(byAdding: .hour, value: 11, to: day)!
        let segment = try store.longestFocusSegment(
            on: day, calendar: calendar, now: now
        )
        #expect(segment != nil)
        #expect(segment?.bundleId == "com.apple.dt.Xcode")
        #expect(segment?.durationSeconds == 2 * 60 * 60)
    }

    @Test("idle minute inside an interval disqualifies it")
    func idleDisqualifies() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        let nineAm = calendar.date(byAdding: .hour, value: 9, to: day)!
        try insertSwitch(into: db, at: nineAm, bundle: "com.apple.dt.Xcode")

        // Idle minute at 09:30 with 45 idle seconds → (60 - 45) = 15 < 30 threshold.
        let nineThirty = calendar.date(byAdding: .minute, value: 30, to: nineAm)!
        try insertIdleMinute(into: db, minuteStart: nineThirty, idleSeconds: 45)

        let now = calendar.date(byAdding: .hour, value: 11, to: day)!
        let segment = try store.longestFocusSegment(
            on: day, calendar: calendar, now: now
        )
        #expect(segment == nil)
    }

    @Test("picks the longest qualifying segment across multiple apps")
    func pickLongestAcrossApps() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        let nineAm = calendar.date(byAdding: .hour, value: 9, to: day)!
        let tenAm = calendar.date(byAdding: .hour, value: 10, to: day)!
        try insertSwitch(into: db, at: nineAm, bundle: "com.apple.Safari")       // 9:00–10:00 = 60 min
        try insertSwitch(into: db, at: tenAm, bundle: "com.apple.dt.Xcode")      // 10:00 onward

        // Query at 12:00 so Xcode covers 10:00–12:00 = 120 min.
        let now = calendar.date(byAdding: .hour, value: 12, to: day)!
        let segment = try #require(
            try store.longestFocusSegment(on: day, calendar: calendar, now: now)
        )
        #expect(segment.bundleId == "com.apple.dt.Xcode")
        #expect(segment.durationSeconds == 2 * 60 * 60)
    }

    @Test("prior-day bundle carries across midnight")
    func priorDayBundleCarries() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        // Switch yesterday at 23:30.
        let priorSwitch = calendar.date(byAdding: .minute, value: -30, to: day)!
        try insertSwitch(into: db, at: priorSwitch, bundle: "com.apple.dt.Xcode")
        // No switches today.
        let now = calendar.date(byAdding: .hour, value: 2, to: day)!
        let segment = try #require(
            try store.longestFocusSegment(on: day, calendar: calendar, now: now)
        )
        // Segment spans 00:00 – 02:00 = 2h (yesterday's trailing 30 min is clipped at dayStart).
        #expect(segment.bundleId == "com.apple.dt.Xcode")
        #expect(segment.durationSeconds == 2 * 60 * 60)
    }

    @Test("empty day with no transitions returns nil")
    func emptyDayReturnsNil() throws {
        let (store, _) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        let now = calendar.date(byAdding: .hour, value: 12, to: day)!
        #expect(try store.longestFocusSegment(on: day, calendar: calendar, now: now) == nil)
    }

    @Test("sub-minute intervals are excluded even when active")
    func subMinuteExcluded() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let day = calendar.date(from: .init(timeZone: calendar.timeZone,
                                            year: 2026, month: 4, day: 17))!
        let nineAm = calendar.date(byAdding: .hour, value: 9, to: day)!
        try insertSwitch(into: db, at: nineAm, bundle: "com.apple.Safari")
        let thirtySecondsLater = nineAm.addingTimeInterval(30)
        try insertSwitch(into: db, at: thirtySecondsLater, bundle: "com.apple.dt.Xcode")

        // Query at 9:01 — Safari lasted 30 s, Xcode 30 s. Neither ≥ 60 s.
        let now = nineAm.addingTimeInterval(60)
        #expect(try store.longestFocusSegment(on: day, calendar: calendar, now: now) == nil)
    }
}

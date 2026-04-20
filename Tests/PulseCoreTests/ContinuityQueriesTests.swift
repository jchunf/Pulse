import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ContinuityQueries — F-11 streak grid")
struct ContinuityQueriesTests {

    // MARK: - Fixtures

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    /// Calendar + reference "today" pinned to UTC so DST and the host
    /// timezone don't perturb day bucketing.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var referenceEnd: Date {
        // 2026-04-18 17:00:00 UTC — mid-day "today" so adding 7 days
        // of window with 4-active-hour days still leaves headroom.
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 18
        components.hour = 17; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    /// Populate `hoursActive` distinct UTC hours of `day` with non-zero
    /// activity (`keys` key presses per hour). 0 hours → day remains
    /// empty.
    private func seedDay(
        _ db: PulseDatabase,
        day: Date,
        activeHours hoursActive: Int,
        keysPerHour keys: Int = 50
    ) throws {
        let dayStart = utcCalendar.startOfDay(for: day)
        for hour in 0..<hoursActive {
            guard let hourStart = utcCalendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
            try db.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                    VALUES (?, ?, 0.0, 0, 0, 0)
                    """,
                    arguments: [Int64(hourStart.timeIntervalSince1970), keys]
                )
            }
        }
    }

    /// The start-of-local-day for `offsetFromEnd` days before the
    /// reference end (offset 0 = today, 1 = yesterday, …).
    private func dayOffset(_ offsetFromEnd: Int) -> Date {
        utcCalendar.date(byAdding: .day, value: -offsetFromEnd, to: referenceEnd)!
    }

    // MARK: - Empty database

    @Test("empty database — zero streaks, one zero-cell per day")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.windowDays == 7)
        #expect(result.days.count == 7)
        #expect(result.days.allSatisfy { $0.activeHours == 0 && !$0.qualified })
        #expect(result.currentStreak == 0)
        #expect(result.longestStreak == 0)
        #expect(result.qualifyingDays == 0)
    }

    // MARK: - Basic streaks

    @Test("today qualifies alone — current and longest are 1")
    func todayOnly() throws {
        let (store, db) = try makeStore()
        try seedDay(db, day: dayOffset(0), activeHours: 4)
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.currentStreak == 1)
        #expect(result.longestStreak == 1)
        #expect(result.qualifyingDays == 1)
        #expect(result.days.last?.qualified == true)
        #expect(result.days.last?.activeHours == 4)
    }

    @Test("all seven days qualify — streak wraps the whole window")
    func wholeWindow() throws {
        let (store, db) = try makeStore()
        for offset in 0..<7 {
            try seedDay(db, day: dayOffset(offset), activeHours: 5)
        }
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.currentStreak == 7)
        #expect(result.longestStreak == 7)
        #expect(result.qualifyingDays == 7)
    }

    @Test("today does not qualify — currentStreak is zero even with prior run")
    func todayBreaksStreak() throws {
        let (store, db) = try makeStore()
        // Days oldest→newest: [Q, Q, Q, Q, Q, Q, _ ] (today unqualified)
        for offset in 1..<7 {
            try seedDay(db, day: dayOffset(offset), activeHours: 4)
        }
        try seedDay(db, day: dayOffset(0), activeHours: 2) // below 4
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.currentStreak == 0)
        #expect(result.longestStreak == 6)
        #expect(result.qualifyingDays == 6)
        #expect(result.days.last?.qualified == false)
        #expect(result.days.last?.activeHours == 2)
    }

    @Test("mid-window gap — longestStreak captures the longer run")
    func midGap() throws {
        let (store, db) = try makeStore()
        // oldest → newest index 0..6 = [Q, Q, _, Q, Q, Q, Q]
        // currentStreak = 4 (anchored at today), longestStreak = 4.
        let qualifyingOffsets = [6, 5, 3, 2, 1, 0]  // days offset from end
        for offset in qualifyingOffsets {
            try seedDay(db, day: dayOffset(offset), activeHours: 4)
        }
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.currentStreak == 4)
        #expect(result.longestStreak == 4)
        #expect(result.qualifyingDays == 6)
    }

    // MARK: - Threshold mechanics

    @Test("configurable threshold respected — 3 active hours passes 3, fails 4")
    func thresholdBoundary() throws {
        let (store, db) = try makeStore()
        try seedDay(db, day: dayOffset(0), activeHours: 3)
        let strict = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 1,
            activeHoursThreshold: 4,
            calendar: utcCalendar
        )
        #expect(strict.currentStreak == 0)
        #expect(strict.qualifyingDays == 0)
        let lenient = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 1,
            activeHoursThreshold: 3,
            calendar: utcCalendar
        )
        #expect(lenient.currentStreak == 1)
        #expect(lenient.qualifyingDays == 1)
    }

    @Test("scroll-only activity counts — not just keys/clicks")
    func scrollCountsAsActivity() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: dayOffset(0))
        for hour in 0..<5 {
            let hourStart = utcCalendar.date(byAdding: .hour, value: hour, to: dayStart)!
            try db.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                    VALUES (?, 0, 0.0, 0, 0, ?)
                    """,
                    arguments: [Int64(hourStart.timeIntervalSince1970), 30]
                )
            }
        }
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 1,
            calendar: utcCalendar
        )
        #expect(result.days.first?.activeHours == 5)
        #expect(result.currentStreak == 1)
    }

    @Test("all-idle hour doesn't count — row with only idle_seconds is ignored")
    func idleOnlyIgnored() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: dayOffset(0))
        for hour in 0..<6 {
            let hourStart = utcCalendar.date(byAdding: .hour, value: hour, to: dayStart)!
            try db.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                    VALUES (?, 0, 0.0, 0, 3600, 0)
                    """,
                    arguments: [Int64(hourStart.timeIntervalSince1970)]
                )
            }
        }
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 1,
            calendar: utcCalendar
        )
        #expect(result.days.first?.activeHours == 0)
        #expect(result.currentStreak == 0)
        #expect(result.qualifyingDays == 0)
    }

    @Test("activity outside the window is ignored")
    func outsideWindow() throws {
        let (store, db) = try makeStore()
        // Data at day offset 10, window only covers the latest 7 days.
        try seedDay(db, day: dayOffset(10), activeHours: 10)
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.qualifyingDays == 0)
        #expect(result.currentStreak == 0)
        #expect(result.longestStreak == 0)
    }

    // MARK: - Shape of `days`

    @Test("days array is ordered oldest → newest and covers every day in the window")
    func daysOrderAndCoverage() throws {
        let (store, db) = try makeStore()
        try seedDay(db, day: dayOffset(0), activeHours: 4)
        let result = try store.continuityStreak(
            endingAt: referenceEnd,
            days: 7,
            calendar: utcCalendar
        )
        #expect(result.days.count == 7)
        // Each entry strictly 86_400 seconds after the previous, in UTC.
        let timestamps = result.days.map { Int($0.day.timeIntervalSince1970) }
        for i in 1..<timestamps.count {
            #expect(timestamps[i] - timestamps[i - 1] == 86_400)
        }
        #expect(result.days.first!.day < result.days.last!.day)
        // Last entry should map to today (startOfDay of referenceEnd).
        #expect(result.days.last!.day == utcCalendar.startOfDay(for: referenceEnd))
    }

    // MARK: - streakStatistics helper (no database)

    @Test("streakStatistics — empty array is 0 / 0")
    func helperEmpty() {
        let (current, longest) = EventStore.streakStatistics([])
        #expect(current == 0)
        #expect(longest == 0)
    }

    @Test("streakStatistics — trailing run anchors current")
    func helperTrailing() {
        let (current, longest) = EventStore.streakStatistics(
            [true, false, true, true, true]
        )
        #expect(current == 3)
        #expect(longest == 3)
    }

    @Test("streakStatistics — broken at end zeroes current, longest is preserved")
    func helperBrokenAtEnd() {
        let (current, longest) = EventStore.streakStatistics(
            [true, true, true, true, false]
        )
        #expect(current == 0)
        #expect(longest == 4)
    }

    @Test("streakStatistics — all true is n / n")
    func helperAllTrue() {
        let (current, longest) = EventStore.streakStatistics(
            Array(repeating: true, count: 10)
        )
        #expect(current == 10)
        #expect(longest == 10)
    }

    @Test("streakStatistics — all false is 0 / 0")
    func helperAllFalse() {
        let (current, longest) = EventStore.streakStatistics(
            Array(repeating: false, count: 10)
        )
        #expect(current == 0)
        #expect(longest == 0)
    }
}

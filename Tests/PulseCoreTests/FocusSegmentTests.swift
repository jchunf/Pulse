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

    // MARK: - Batched query (A35 perf)

    @Test("batched durations match the per-day loop output")
    func batchedMatchesLoop() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let endingDay = calendar.date(from: .init(timeZone: calendar.timeZone,
                                                  year: 2026, month: 4, day: 17))!
        // Build a 6-day window of mixed activity:
        //   day -1 (yesterday): a 3-hour Xcode block (qualifies)
        //   day -2: empty (returns nil)
        //   day -3: a 90-minute Safari block (qualifies)
        //   day -4: a 2-hour block disqualified by an idle minute
        //   day -5: an interval crossing midnight from day -6
        //   day -6: a 1-hour Notes block (qualifies)
        for dayOffset in 1...6 {
            guard let dayStart = calendar.date(
                byAdding: .day, value: -dayOffset, to: endingDay
            ) else { continue }
            let nine = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
            switch dayOffset {
            case 1:  // 3-hour Xcode
                try insertSwitch(into: db, at: nine, bundle: "com.apple.dt.Xcode")
                try insertSwitch(
                    into: db,
                    at: calendar.date(byAdding: .hour, value: 12, to: dayStart)!,
                    bundle: "com.apple.Safari"
                )
            case 3:  // 90-minute Safari
                try insertSwitch(into: db, at: nine, bundle: "com.apple.Safari")
                try insertSwitch(
                    into: db,
                    at: calendar.date(byAdding: .minute, value: 90, to: nine)!,
                    bundle: "com.apple.dt.Xcode"
                )
            case 4:  // 2-hour disqualified by idle minute
                try insertSwitch(into: db, at: nine, bundle: "com.apple.dt.Xcode")
                try insertIdleMinute(
                    into: db,
                    minuteStart: calendar.date(byAdding: .minute, value: 30, to: nine)!,
                    idleSeconds: 45
                )
                try insertSwitch(
                    into: db,
                    at: calendar.date(byAdding: .hour, value: 11, to: dayStart)!,
                    bundle: "com.apple.Safari"
                )
            case 6:  // 1-hour Notes
                try insertSwitch(into: db, at: nine, bundle: "com.apple.Notes")
                try insertSwitch(
                    into: db,
                    at: calendar.date(byAdding: .hour, value: 10, to: dayStart)!,
                    bundle: "com.apple.Safari"
                )
            default:
                break
            }
        }

        let batched = try store.longestFocusDurationsForPreviousDays(
            endingAt: endingDay,
            days: 6,
            calendar: calendar
        )

        // Compare against the loop version. `endingDay - 1 day` is index 0.
        var loopDurations: [Int?] = []
        for offset in 1...6 {
            let day = calendar.date(byAdding: .day, value: -offset, to: endingDay)!
            // The single-day query honors `now` for clamping; for past
            // days, supply a `now` strictly inside the day so the
            // window covers the full 24h (matching the batched method
            // which never clamps by `now` for previous days).
            let now = calendar.date(byAdding: .hour, value: 23, to: day)!
            let seg = try? store.longestFocusSegment(
                on: day, calendar: calendar, now: now
            )
            loopDurations.append(seg?.durationSeconds)
        }
        #expect(batched == loopDurations)

        // Also assert specific tier values so a regression in the
        // batched logic shows up as a wrong number, not just a
        // diff-from-loop hash:
        //   index 0 = yesterday  → 3 h Xcode
        //   index 1 = day -2     → no activity
        //   index 2 = day -3     → 90 min Safari
        //   index 3 = day -4     → disqualified
        //   index 4 = day -5     → no activity
        //   index 5 = day -6     → 1 h Notes
        #expect(batched[0] == 3 * 60 * 60)
        #expect(batched[1] == nil)
        #expect(batched[2] == 90 * 60)
        #expect(batched[3] == nil)
        #expect(batched[4] == nil)
        #expect(batched[5] == 60 * 60)
    }

    @Test("batched returns all-nil for an empty store")
    func batchedEmptyStore() throws {
        let (store, _) = try makeStore()
        let calendar = utcCalendar
        let endingDay = calendar.date(from: .init(timeZone: calendar.timeZone,
                                                  year: 2026, month: 4, day: 17))!
        let result = try store.longestFocusDurationsForPreviousDays(
            endingAt: endingDay,
            days: 4,
            calendar: calendar
        )
        #expect(result.count == 4)
        #expect(result.allSatisfy { $0 == nil })
    }

    @Test("batched correctly attributes a midnight-spanning bundle to both days")
    func batchedMidnightSpan() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar
        let endingDay = calendar.date(from: .init(timeZone: calendar.timeZone,
                                                  year: 2026, month: 4, day: 17))!
        // Day-2 starts at 2026-04-15 00:00 UTC; insert a switch at
        // 2026-04-15 22:00 → the same bundle stays foreground until
        // 2026-04-16 02:00. Both day-2 (2 h before midnight) and
        // day-1 (2 h after) should report 2-hour qualifying
        // segments.
        let dayMinusTwo = calendar.date(byAdding: .day, value: -2, to: endingDay)!
        let twentyTwo = calendar.date(byAdding: .hour, value: 22, to: dayMinusTwo)!
        try insertSwitch(into: db, at: twentyTwo, bundle: "com.apple.dt.Xcode")
        let nextDayTwoAm = calendar.date(byAdding: .hour, value: 4, to: twentyTwo)!
        try insertSwitch(into: db, at: nextDayTwoAm, bundle: "com.apple.Safari")

        let batched = try store.longestFocusDurationsForPreviousDays(
            endingAt: endingDay,
            days: 3,
            calendar: calendar
        )
        // index 0 = day -1 (yesterday) → 02:00 segment (2 h)
        // index 1 = day -2 → 22:00–24:00 segment (2 h)
        #expect(batched[0] == 2 * 60 * 60)
        #expect(batched[1] == 2 * 60 * 60)
        #expect(batched[2] == nil)
    }
}

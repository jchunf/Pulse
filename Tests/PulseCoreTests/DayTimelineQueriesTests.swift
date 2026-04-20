import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("DayTimelineQueries — F-10 foreground-app band")
struct DayTimelineQueriesTests {

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

    private func insertSwitch(
        _ db: PulseDatabase,
        bundle: String,
        at instant: Date
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000), bundle]
            )
        }
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        let day = utcCalendar.startOfDay(for: referenceNow)
        return utcCalendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    // MARK: - Empty / no data

    @Test("empty database — zero segments, dayStart/dayEnd still set to today's bounds")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.isEmpty)
        #expect(timeline.dayStart == utcCalendar.startOfDay(for: referenceNow))
        #expect(timeline.dayEnd == referenceNow)
        #expect(timeline.segments.isEmpty)
    }

    // MARK: - Basic walk

    @Test("three switches — three segments, last closes at capUntil")
    func threeSwitches() throws {
        let (store, db) = try makeStore()
        try insertSwitch(db, bundle: "com.apple.Terminal", at: at(9, 0))
        try insertSwitch(db, bundle: "com.google.Chrome",  at: at(11, 0))
        try insertSwitch(db, bundle: "com.apple.dt.Xcode", at: at(14, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.segments.count == 3)
        #expect(timeline.segments[0].bundleId == "com.apple.Terminal")
        #expect(timeline.segments[0].durationSeconds == 2 * 3_600)
        #expect(timeline.segments[1].bundleId == "com.google.Chrome")
        #expect(timeline.segments[1].durationSeconds == 3 * 3_600)
        #expect(timeline.segments[2].bundleId == "com.apple.dt.Xcode")
        #expect(timeline.segments[2].durationSeconds == 3 * 3_600) // 14:00 → 17:00
    }

    // MARK: - Prior bundle carry-over

    @Test("prior-day bundle fills the pre-first-switch segment")
    func priorBundleCarryover() throws {
        let (store, db) = try makeStore()
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: referenceNow)!
        // Bundle active since yesterday 23:00 — should fill 00:00 → 09:00 today.
        try insertSwitch(
            db,
            bundle: "com.apple.Safari",
            at: utcCalendar.date(byAdding: .hour, value: 23, to: utcCalendar.startOfDay(for: yesterday))!
        )
        try insertSwitch(db, bundle: "com.apple.Terminal", at: at(9, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.segments.count == 2)
        #expect(timeline.segments[0].bundleId == "com.apple.Safari")
        #expect(timeline.segments[0].durationSeconds == 9 * 3_600)
        #expect(timeline.segments[1].bundleId == "com.apple.Terminal")
        #expect(timeline.segments[1].durationSeconds == 8 * 3_600) // 09:00 → 17:00
    }

    @Test("no prior and no events today — empty timeline, not a full-day placeholder")
    func noPriorNoEvents() throws {
        let (store, _) = try makeStore()
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.isEmpty)
    }

    // MARK: - capUntil clamp

    @Test("tail segment ends exactly at capUntil")
    func tailEndsAtCap() throws {
        let (store, db) = try makeStore()
        try insertSwitch(db, bundle: "com.apple.Terminal", at: at(10, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.segments.count == 1)
        #expect(timeline.segments[0].endedAt == referenceNow)
    }

    @Test("capUntil before dayStart produces an empty timeline")
    func capBeforeDay() throws {
        let (store, _) = try makeStore()
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: referenceNow)!
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: yesterday,
            calendar: utcCalendar
        )
        #expect(timeline.isEmpty)
        #expect(timeline.dayStart == timeline.dayEnd)
    }

    // MARK: - Same-second duplicate transitions

    @Test("back-to-back same-second switches produce zero-duration gaps and skip them")
    func sameSecondSwitches() throws {
        let (store, db) = try makeStore()
        // Terminal at 09:00, Chrome at 09:00 (same timestamp).
        try insertSwitch(db, bundle: "com.apple.Terminal", at: at(9, 0))
        try insertSwitch(db, bundle: "com.google.Chrome",  at: at(9, 0))
        try insertSwitch(db, bundle: "com.apple.dt.Xcode", at: at(12, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        // Terminal → Chrome at the same ts should skip Terminal; Chrome
        // runs 09:00 → 12:00, then Xcode 12:00 → 17:00.
        #expect(timeline.segments.count == 2)
        #expect(timeline.segments[0].bundleId == "com.google.Chrome")
        #expect(timeline.segments[0].durationSeconds == 3 * 3_600)
        #expect(timeline.segments[1].bundleId == "com.apple.dt.Xcode")
    }

    // MARK: - topBundles helper

    @Test("topBundles sums across non-adjacent segments, sorted descending")
    func topBundles() throws {
        let (store, db) = try makeStore()
        try insertSwitch(db, bundle: "A", at: at(9, 0))
        try insertSwitch(db, bundle: "B", at: at(10, 0))
        try insertSwitch(db, bundle: "A", at: at(11, 0))
        try insertSwitch(db, bundle: "C", at: at(14, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        let top = timeline.topBundles(limit: 3)
        // A: 1h + 3h = 4h. C: 3h. B: 1h.
        #expect(top.count == 3)
        #expect(top[0].bundleId == "A")
        #expect(top[0].totalSeconds == 4 * 3_600)
        #expect(top[1].bundleId == "C")
        #expect(top[1].totalSeconds == 3 * 3_600)
        #expect(top[2].bundleId == "B")
        #expect(top[2].totalSeconds == 1 * 3_600)
    }

    @Test("topBundles honours the limit argument")
    func topBundlesLimit() throws {
        let (store, db) = try makeStore()
        try insertSwitch(db, bundle: "A", at: at(8, 0))
        try insertSwitch(db, bundle: "B", at: at(10, 0))
        try insertSwitch(db, bundle: "C", at: at(12, 0))
        try insertSwitch(db, bundle: "D", at: at(14, 0))
        let timeline = try store.dayTimeline(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(timeline.topBundles(limit: 2).count == 2)
    }
}

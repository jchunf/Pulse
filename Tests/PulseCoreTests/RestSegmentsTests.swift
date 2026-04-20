import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("RestSegments — F-26 idle pairing")
struct RestSegmentsTests {

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

    private func insertIdleEvent(
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

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        let day = utcCalendar.startOfDay(for: referenceNow)
        return utcCalendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    // MARK: - Empty / no data

    @Test("empty database — zero segments")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.segments.isEmpty)
        #expect(day.count == 0)
        #expect(day.totalSeconds == 0)
        #expect(day.longestSeconds == 0)
    }

    // MARK: - Pairing

    @Test("paired entered/exited produces one completed segment")
    func singleSegment() throws {
        let (store, db) = try makeStore()
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 0))
        try insertIdleEvent(db, category: "idle_exited", at: at(10, 30))
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 1)
        #expect(day.totalSeconds == 30 * 60)
        #expect(day.longestSeconds == 30 * 60)
    }

    @Test("three segments — count, total, and longest all match")
    func threeSegments() throws {
        let (store, db) = try makeStore()
        // 10:00–10:30 (30 min), 12:00–12:15 (15 min), 15:00–16:00 (60 min)
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(10, 30))
        try insertIdleEvent(db, category: "idle_entered", at: at(12, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(12, 15))
        try insertIdleEvent(db, category: "idle_entered", at: at(15, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(16, 0))
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 3)
        #expect(day.totalSeconds == (30 + 15 + 60) * 60)
        #expect(day.longestSeconds == 60 * 60)
    }

    // MARK: - Open segment handling

    @Test("ongoing idle is closed at capUntil so today's partial rest is visible")
    func ongoingIdle() throws {
        let (store, db) = try makeStore()
        try insertIdleEvent(db, category: "idle_entered", at: at(16, 30))
        // No matching exit; capUntil is 17:00 → 30-min open segment.
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 1)
        #expect(day.totalSeconds == 30 * 60)
    }

    @Test("orphaned idle_exited is ignored (no preceding idle_entered today)")
    func orphanedExit() throws {
        let (store, db) = try makeStore()
        try insertIdleEvent(db, category: "idle_exited", at: at(9, 0))
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(10, 30))
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 1)
        #expect(day.totalSeconds == 30 * 60)
    }

    @Test("two idle_entered in a row — later one wins, earlier is dropped")
    func doubleEntered() throws {
        let (store, db) = try makeStore()
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 0))
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 20)) // lost the pair
        try insertIdleEvent(db, category: "idle_exited",  at: at(10, 30))
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 1)
        // Measured from the second idle_entered (10:20) to exit (10:30) = 10 min.
        #expect(day.totalSeconds == 10 * 60)
    }

    @Test("yesterday's events never land in today's result")
    func scopedToToday() throws {
        let (store, db) = try makeStore()
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: referenceNow)!
        let yDay = utcCalendar.startOfDay(for: yesterday)
        try insertIdleEvent(db, category: "idle_entered", at: yDay.addingTimeInterval(10 * 3600))
        try insertIdleEvent(db, category: "idle_exited",  at: yDay.addingTimeInterval(10 * 3600 + 1800))
        // Only yesterday's rest exists — today must be empty.
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 0)
    }

    @Test("events past capUntil are ignored")
    func capUntilClamp() throws {
        let (store, db) = try makeStore()
        // capUntil = 17:00, but idle_entered at 18:00 → ignored entirely.
        try insertIdleEvent(db, category: "idle_entered", at: at(18, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(19, 0))
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 0)
    }

    @Test("zero-duration exit immediately after entered is dropped (noise)")
    func zeroDurationDropped() throws {
        let (store, db) = try makeStore()
        try insertIdleEvent(db, category: "idle_entered", at: at(10, 0))
        try insertIdleEvent(db, category: "idle_exited",  at: at(10, 0)) // same ts
        let day = try store.restSegments(
            on: referenceNow,
            capUntil: referenceNow,
            calendar: utcCalendar
        )
        #expect(day.count == 0) // instant > start required
    }
}

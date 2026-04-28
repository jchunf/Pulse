import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ClipboardQueries — F-32 clipboard-change frequency")
struct ClipboardQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var noon: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 18; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func insertClipboard(into db: PulseDatabase, ts: Date) throws {
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO system_events (ts, category, payload) VALUES (?, 'clipboard_change', NULL)
                """, arguments: [Int64(ts.timeIntervalSince1970 * 1_000)])
        }
    }

    @Test("empty database — 0 changes")
    func empty() throws {
        let (store, _) = try makeStore()
        let count = try store.dailyClipboardChanges(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(count == 0)
        let hourly = try store.hourlyClipboardChanges(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(hourly.count == 24)
        #expect(hourly.allSatisfy { $0 == 0 })
    }

    @Test("dailyClipboardChanges counts events in window")
    func dailyCount() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        for offset in [0, 60, 120, 600, 7200] {
            try insertClipboard(into: db, ts: dayStart.addingTimeInterval(TimeInterval(offset)))
        }
        let count = try store.dailyClipboardChanges(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(count == 5)
    }

    @Test("activity outside the day is excluded")
    func windowed() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // Yesterday: 3 events.
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(-3600))
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(-1800))
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(-60))
        // Today: 1 event.
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(60))
        let count = try store.dailyClipboardChanges(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(count == 1)
    }

    @Test("capUntil clamps the trailing edge")
    func capUntilClamps() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // 09:00, 10:00, 11:00, 13:00 → cap at noon = 3 events.
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(9 * 3600))
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(10 * 3600))
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(11 * 3600))
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(13 * 3600))
        let count = try store.dailyClipboardChanges(on: noon, capUntil: noon, calendar: utcCalendar)
        #expect(count == 3)
    }

    @Test("hourlyClipboardChanges pivots events into 24 hour-of-day slots")
    func hourlyDistribution() throws {
        let (store, db) = try makeStore()
        let dayStart = utcCalendar.startOfDay(for: noon)
        // 3 events at 09:00, 2 at 10:00, 1 at 14:00.
        for _ in 0..<3 {
            try insertClipboard(into: db, ts: dayStart.addingTimeInterval(9 * 3600))
        }
        for _ in 0..<2 {
            try insertClipboard(into: db, ts: dayStart.addingTimeInterval(10 * 3600))
        }
        try insertClipboard(into: db, ts: dayStart.addingTimeInterval(14 * 3600))

        let dayEnd = utcCalendar.date(byAdding: .day, value: 1, to: dayStart)!
        let hourly = try store.hourlyClipboardChanges(
            on: noon,
            capUntil: dayEnd,
            calendar: utcCalendar
        )
        #expect(hourly[9] == 3)
        #expect(hourly[10] == 2)
        #expect(hourly[14] == 1)
        for h in 0..<24 where ![9, 10, 14].contains(h) {
            #expect(hourly[h] == 0)
        }
    }
}

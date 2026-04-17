import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("SessionPosture — session rhythm statistics (review §3.6)")
struct UsagePostureTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func insertForeground(
        into db: PulseDatabase,
        events: [(tsMs: Int64, bundle: String)]
    ) throws {
        try db.queue.write { db in
            for ev in events {
                try db.execute(
                    sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                    arguments: [ev.tsMs, ev.bundle]
                )
            }
        }
    }

    @Test("from(durationsSeconds:) returns empty for no sessions")
    func pureEmpty() {
        let posture = SessionPosture.from(durationsSeconds: [])
        #expect(posture == .empty)
        #expect(posture.sessionCount == 0)
    }

    @Test("from(durationsSeconds:) computes median correctly for even and odd counts")
    func pureMedian() {
        let odd = SessionPosture.from(durationsSeconds: [300, 900, 60])
        #expect(odd.medianDurationSeconds == 300) // sorted: 60, 300, 900
        #expect(odd.averageDurationSeconds == 420) // (300+900+60)/3
        #expect(odd.shortestDurationSeconds == 60)
        #expect(odd.longestDurationSeconds == 900)

        let even = SessionPosture.from(durationsSeconds: [100, 200, 300, 400])
        #expect(even.medianDurationSeconds == 250) // (200+300)/2
    }

    @Test("session query skips intervals below the minimum threshold")
    func subMinuteIntervalsAreSkipped() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 4, day: 17
        ))!
        let dayMs = Int64(day.timeIntervalSince1970 * 1_000)
        let now = calendar.date(byAdding: .hour, value: 12, to: day)!

        // app A from minute 0 → 0:05 (300s, kept)
        // app B from 0:05 → 0:05:30 (30s, dropped)
        // app C from 0:05:30 → 0:40 (2070s, kept)
        try insertForeground(into: db, events: [
            (tsMs: dayMs, bundle: "A"),
            (tsMs: dayMs + 300_000, bundle: "B"),
            (tsMs: dayMs + 330_000, bundle: "C"),
            (tsMs: dayMs + 2_400_000, bundle: "D") // sentinel close
        ])

        let posture = try store.sessionPosture(
            on: day, minSessionSeconds: 60,
            calendar: calendar, now: now
        )
        #expect(posture.sessionCount == 2)
        #expect(posture.shortestDurationSeconds == 300)
        #expect(posture.longestDurationSeconds == 2070)
    }

    @Test("empty day returns empty posture")
    func emptyDay() throws {
        let (store, _) = try makeStore()
        let calendar = utcCalendar()
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 4, day: 17
        ))!
        let now = calendar.date(byAdding: .hour, value: 12, to: day)!
        let posture = try store.sessionPosture(
            on: day, calendar: calendar, now: now
        )
        #expect(posture == .empty)
    }

    @Test("priorBundle from yesterday counts the carry-over interval")
    func priorBundleCarriesAcross() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 4, day: 17
        ))!
        let dayMs = Int64(day.timeIntervalSince1970 * 1_000)
        let yesterdayTailMs = dayMs - 600_000 // 10 min before midnight
        let now = calendar.date(byAdding: .hour, value: 2, to: day)! // 02:00

        try insertForeground(into: db, events: [
            (tsMs: yesterdayTailMs, bundle: "PriorApp"),
            (tsMs: dayMs + 3_600_000, bundle: "NextApp") // switch at 01:00
        ])

        let posture = try store.sessionPosture(
            on: day, minSessionSeconds: 60,
            calendar: calendar, now: now
        )
        // Expected sessions on the day:
        //  - PriorApp from midnight → 01:00 (3600s) — counts
        //  - NextApp from 01:00 → now (02:00) (3600s) — counts
        #expect(posture.sessionCount == 2)
        #expect(posture.averageDurationSeconds == 3600)
        #expect(posture.medianDurationSeconds == 3600)
    }

    @Test("caps at `now`, does not include the whole future day")
    func capsAtNow() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 4, day: 17
        ))!
        let dayMs = Int64(day.timeIntervalSince1970 * 1_000)
        let now = calendar.date(byAdding: .hour, value: 3, to: day)! // 03:00 only

        try insertForeground(into: db, events: [
            (tsMs: dayMs + 0, bundle: "A"),
            (tsMs: dayMs + 3_600_000, bundle: "B")     // 01:00 switch
            // no close; trailing segment extends to now, not end-of-day.
        ])
        let posture = try store.sessionPosture(
            on: day, minSessionSeconds: 60,
            calendar: calendar, now: now
        )
        // Session A: 0 → 01:00 → 3600s
        // Session B: 01:00 → 03:00 (now) → 7200s
        #expect(posture.sessionCount == 2)
        #expect(posture.shortestDurationSeconds == 3600)
        #expect(posture.longestDurationSeconds == 7200)
    }
}

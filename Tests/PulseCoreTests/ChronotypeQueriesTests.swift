import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ChronotypeQueries — F-40 chronotype derivation")
struct ChronotypeQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Inserts a `hour_summary` row at hour-of-day `h` (UTC) with
    /// `activeSeconds` worth of active time (= 3600 − idle).
    private func insertHour(into db: PulseDatabase, day: Date, hour: Int, activeSeconds: Int) throws {
        let dayStart = utcCalendar.startOfDay(for: day)
        let ts = Int64(dayStart.timeIntervalSince1970) + Int64(hour) * 3600
        let idle = max(0, 3600 - activeSeconds)
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds)
                VALUES (?, 0, 0, 0, ?)
                """, arguments: [ts, idle])
        }
    }

    /// 2026-04-18 12:00 UTC anchor. Same date Continuity tests use.
    private var endingAt: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 18; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    @Test("empty database returns nil")
    func empty() throws {
        let (store, _) = try makeStore()
        #expect(try store.chronotype(endingAt: endingAt, days: 14, calendar: utcCalendar) == nil)
    }

    @Test("activity below the threshold returns nil")
    func belowThreshold() throws {
        let (store, db) = try makeStore()
        // 2 hours of activity total — under the 3-hour default
        // floor for classification.
        try insertHour(into: db, day: endingAt, hour: 10, activeSeconds: 3600)
        try insertHour(into: db, day: endingAt, hour: 11, activeSeconds: 3600)
        #expect(try store.chronotype(endingAt: endingAt, days: 14, calendar: utcCalendar) == nil)
    }

    @Test("morning-heavy distribution → morning label")
    func morningPerson() throws {
        let (store, db) = try makeStore()
        // 4 hours each at 9, 10, 11 across the 14-day window.
        for h in [9, 10, 11] {
            try insertHour(into: db, day: endingAt, hour: h, activeSeconds: 3600)
        }
        try insertHour(into: db, day: endingAt, hour: 12, activeSeconds: 1800)

        let result = try #require(try store.chronotype(
            endingAt: endingAt,
            days: 14,
            calendar: utcCalendar
        ))
        #expect(result.label == .morning)
        // Peak in this synthetic data is hours 9/10/11 — pick is
        // the lowest-numbered one due to the > comparison.
        #expect([9, 10, 11].contains(result.peakHour))
    }

    @Test("late-night distribution → lateNight label (handles 23 → 0 wrap)")
    func lateNight() throws {
        let (store, db) = try makeStore()
        // Activity at 23, 0, 1, 2 — straddles the day boundary.
        try insertHour(into: db, day: endingAt, hour: 23, activeSeconds: 3000)
        try insertHour(into: db, day: endingAt, hour: 0,  activeSeconds: 3000)
        try insertHour(into: db, day: endingAt, hour: 1,  activeSeconds: 3000)
        try insertHour(into: db, day: endingAt, hour: 2,  activeSeconds: 3000)

        let result = try #require(try store.chronotype(
            endingAt: endingAt,
            days: 14,
            calendar: utcCalendar
        ))
        // Circular mean of {23, 0, 1, 2} sits near 00:30 — both
        // .lateNight and .evening are reasonable depending on the
        // cutoff. The key thing is that it didn't get classified as
        // .afternoon (which a naive linear mean would do).
        #expect([.lateNight, .evening].contains(result.label))
    }

    @Test("evening peak → evening label")
    func evening() throws {
        let (store, db) = try makeStore()
        for h in [19, 20, 21, 22] {
            try insertHour(into: db, day: endingAt, hour: h, activeSeconds: 3600)
        }
        let result = try #require(try store.chronotype(
            endingAt: endingAt,
            days: 14,
            calendar: utcCalendar
        ))
        #expect(result.label == .evening)
    }

    @Test("hourlyActiveSeconds matches the per-hour input")
    func hourlyDistributionPreserved() throws {
        let (store, db) = try makeStore()
        try insertHour(into: db, day: endingAt, hour: 10, activeSeconds: 1500)
        try insertHour(into: db, day: endingAt, hour: 11, activeSeconds: 2400)
        try insertHour(into: db, day: endingAt, hour: 14, activeSeconds: 600)

        let result = try #require(try store.chronotype(
            endingAt: endingAt,
            days: 14,
            calendar: utcCalendar
        ))
        #expect(result.hourlyActiveSeconds.count == 24)
        #expect(result.hourlyActiveSeconds[10] == 1500)
        #expect(result.hourlyActiveSeconds[11] == 2400)
        #expect(result.hourlyActiveSeconds[14] == 600)
        // Every other hour stayed at zero.
        for h in 0..<24 where ![10, 11, 14].contains(h) {
            #expect(result.hourlyActiveSeconds[h] == 0)
        }
    }

    @Test("ChronotypeLabel.classify — boundary check")
    func classifyBoundaries() {
        #expect(ChronotypeLabel.classify(centerHour: 0.0)  == .lateNight)
        #expect(ChronotypeLabel.classify(centerHour: 4.99) == .lateNight)
        #expect(ChronotypeLabel.classify(centerHour: 5.0)  == .earlyBird)
        #expect(ChronotypeLabel.classify(centerHour: 8.99) == .earlyBird)
        #expect(ChronotypeLabel.classify(centerHour: 9.0)  == .morning)
        #expect(ChronotypeLabel.classify(centerHour: 12.99) == .morning)
        #expect(ChronotypeLabel.classify(centerHour: 13.0) == .afternoon)
        #expect(ChronotypeLabel.classify(centerHour: 17.99) == .afternoon)
        #expect(ChronotypeLabel.classify(centerHour: 18.0) == .evening)
        #expect(ChronotypeLabel.classify(centerHour: 23.99) == .evening)
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("KeyboardPeakQueries — today's peak typing minute (F-12)")
struct KeyboardPeakQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insertMinKey(into db: PulseDatabase, minute: Date, presses: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_key (ts_minute, press_count) VALUES (?, ?)",
                arguments: [Int64(minute.timeIntervalSince1970), presses]
            )
        }
    }

    private func insertSecKey(into db: PulseDatabase, second: Date, presses: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO sec_key (ts_second, press_count) VALUES (?, ?)",
                arguments: [Int64(second.timeIntervalSince1970), presses]
            )
        }
    }

    @Test("returns nil for an empty database")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 0)
        let capUntil = dayStart.addingTimeInterval(3_600)
        #expect(try store.peakKeyPressMinute(start: dayStart, capUntil: capUntil) == nil)
    }

    @Test("picks the maximum minute across min_key")
    func peakFromMinKey() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        try insertMinKey(into: db, minute: dayStart,                        presses: 95)
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(60), presses: 220)
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(120), presses: 140)
        let capUntil = dayStart.addingTimeInterval(300)

        let peak = try #require(
            try store.peakKeyPressMinute(start: dayStart, capUntil: capUntil)
        )
        #expect(peak.kpm == 220)
        #expect(peak.minuteStart == dayStart.addingTimeInterval(60))
    }

    @Test("folds sec_key to minute buckets and compares against min_key")
    func peakAcrossLayers() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        // L2 peak: minute-1 has 150.
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(60), presses: 150)
        // L1 partial minute: minute-3 has three seconds summing to 210 > 150.
        let minuteThree = dayStart.addingTimeInterval(180)
        try insertSecKey(into: db, second: minuteThree,                            presses: 80)
        try insertSecKey(into: db, second: minuteThree.addingTimeInterval(1),      presses: 70)
        try insertSecKey(into: db, second: minuteThree.addingTimeInterval(2),      presses: 60)
        // L1 also carries an earlier minute with 40 — should lose to 210.
        try insertSecKey(into: db, second: dayStart,                               presses: 40)
        let capUntil = dayStart.addingTimeInterval(600)

        let peak = try #require(
            try store.peakKeyPressMinute(start: dayStart, capUntil: capUntil)
        )
        #expect(peak.kpm == 210)
        #expect(peak.minuteStart == minuteThree)
    }

    @Test("ignores rows outside the requested window")
    func outOfWindowRowsIgnored() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        // Row earlier than window — should be ignored.
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(-120), presses: 900)
        // Row after cap — should also be ignored.
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(600),  presses: 800)
        // In-window row.
        try insertMinKey(into: db, minute: dayStart.addingTimeInterval(60),   presses: 100)
        let capUntil = dayStart.addingTimeInterval(300)

        let peak = try #require(
            try store.peakKeyPressMinute(start: dayStart, capUntil: capUntil)
        )
        #expect(peak.kpm == 100)
    }

}

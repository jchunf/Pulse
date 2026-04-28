import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("KeyboardRhythmQueries — F-19 typing-cadence sparkline")
struct KeyboardRhythmQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    /// Aligned to a minute boundary so per-minute math is exact.
    private var anchor: Date {
        Date(timeIntervalSince1970: 1_776_000_000)
    }

    private func insertMinKey(into db: PulseDatabase, minute: Date, presses: Int) throws {
        let ts = Int64(minute.timeIntervalSince1970)
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO min_key (ts_minute, press_count)
                VALUES (?, ?)
                """, arguments: [ts, presses])
        }
    }

    @Test("empty database returns one zero-sample per minute in the window")
    func empty() throws {
        let (store, _) = try makeStore()
        let rhythm = try store.keyboardRhythm(endingAt: anchor, minutes: 60)
        #expect(rhythm.samples.count == 60)
        #expect(rhythm.peakKPM == 0)
        #expect(rhythm.avgKPMActive == 0)
        #expect(rhythm.totalPresses == 0)
    }

    @Test("populated minutes appear in chronological order")
    func chronologicalOrder() throws {
        let (store, db) = try makeStore()
        // Insert at three different minutes inside the last hour.
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-50 * 60), presses: 10)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-25 * 60), presses: 40)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-1  * 60), presses: 80)

        let rhythm = try store.keyboardRhythm(endingAt: anchor, minutes: 60)
        #expect(rhythm.samples.count == 60)

        let nonZero = rhythm.samples.filter { $0.pressCount > 0 }
        #expect(nonZero.map(\.pressCount) == [10, 40, 80])
        // Chronologically ascending.
        for i in 1..<nonZero.count {
            #expect(nonZero[i].minuteStart > nonZero[i - 1].minuteStart)
        }
    }

    @Test("peakKPM tracks the maximum minute")
    func peak() throws {
        let (store, db) = try makeStore()
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-30 * 60), presses: 12)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-10 * 60), presses: 95)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-3  * 60), presses: 7)
        let rhythm = try store.keyboardRhythm(endingAt: anchor, minutes: 60)
        #expect(rhythm.peakKPM == 95)
    }

    @Test("avgKPMActive ignores zero-press minutes")
    func avgActiveOnly() throws {
        let (store, db) = try makeStore()
        // 3 active minutes with values 60, 40, 20 — avg should be 40,
        // not (60+40+20) / 60.
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-50 * 60), presses: 60)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-30 * 60), presses: 40)
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-10 * 60), presses: 20)
        let rhythm = try store.keyboardRhythm(endingAt: anchor, minutes: 60)
        #expect(rhythm.avgKPMActive == 40)
    }

    @Test("activity outside the window is ignored")
    func windowed() throws {
        let (store, db) = try makeStore()
        // 2 hours back — well past the 60-minute window.
        try insertMinKey(into: db, minute: anchor.addingTimeInterval(-120 * 60), presses: 999)
        let rhythm = try store.keyboardRhythm(endingAt: anchor, minutes: 60)
        #expect(rhythm.peakKPM == 0)
        #expect(rhythm.totalPresses == 0)
    }
}

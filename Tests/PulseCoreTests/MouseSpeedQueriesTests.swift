import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("MouseSpeedQueries — F-18 mouse-speed sparkline")
struct MouseSpeedQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    /// Aligned to a minute boundary.
    private var anchor: Date {
        Date(timeIntervalSince1970: 1_776_000_000)
    }

    private func insertMinMouse(into db: PulseDatabase, minute: Date, distanceMm: Double, moves: Int = 1) throws {
        let ts = Int64(minute.timeIntervalSince1970)
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO min_mouse (ts_minute, move_events, click_events, scroll_ticks, distance_mm)
                VALUES (?, ?, 0, 0, ?)
                """, arguments: [ts, moves, distanceMm])
        }
    }

    @Test("empty database returns one zero-sample per minute in window")
    func empty() throws {
        let (store, _) = try makeStore()
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        #expect(rhythm.samples.count == 60)
        #expect(rhythm.peakMmPerSecond == 0)
        #expect(rhythm.avgMmPerSecondActive == 0)
        #expect(rhythm.totalMoveEvents == 0)
    }

    @Test("60mm distance over a minute reads back as 1mm/s")
    func basicSpeed() throws {
        let (store, db) = try makeStore()
        // 60mm in 1 minute = 1 mm/s.
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-1 * 60), distanceMm: 60, moves: 100)
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        let active = rhythm.samples.filter { $0.mmPerSecond > 0 }
        #expect(active.count == 1)
        #expect(active[0].mmPerSecond == 1.0)
        #expect(active[0].moveEvents == 100)
    }

    @Test("samples are chronologically ordered")
    func chronologicalOrder() throws {
        let (store, db) = try makeStore()
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-50 * 60), distanceMm: 30)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-25 * 60), distanceMm: 120)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-1  * 60), distanceMm: 60)
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        let active = rhythm.samples.filter { $0.mmPerSecond > 0 }
        #expect(active.map(\.mmPerSecond) == [0.5, 2.0, 1.0])
        for i in 1..<active.count {
            #expect(active[i].minuteStart > active[i - 1].minuteStart)
        }
    }

    @Test("peakMmPerSecond tracks the fastest minute")
    func peak() throws {
        let (store, db) = try makeStore()
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-50 * 60), distanceMm: 30)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-10 * 60), distanceMm: 600)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-3  * 60), distanceMm: 6)
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        #expect(rhythm.peakMmPerSecond == 10.0)
    }

    @Test("avgMmPerSecondActive ignores zero-distance minutes")
    func avgActiveOnly() throws {
        let (store, db) = try makeStore()
        // 3 active minutes: 60mm, 120mm, 30mm → speeds 1, 2, 0.5; avg = (1+2+0.5)/3 ≈ 1.167
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-50 * 60), distanceMm: 60)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-30 * 60), distanceMm: 120)
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-10 * 60), distanceMm: 30)
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        // 0.5 + 1.0 + 2.0 = 3.5; avg = 3.5 / 3 ≈ 1.1666...
        #expect(abs(rhythm.avgMmPerSecondActive - (3.5 / 3.0)) < 0.0001)
    }

    @Test("activity outside the window is ignored")
    func windowed() throws {
        let (store, db) = try makeStore()
        // 2h back — past the 60-minute window.
        try insertMinMouse(into: db, minute: anchor.addingTimeInterval(-120 * 60), distanceMm: 6000)
        let rhythm = try store.mouseSpeed(endingAt: anchor, minutes: 60)
        #expect(rhythm.peakMmPerSecond == 0)
        #expect(rhythm.totalMoveEvents == 0)
    }
}

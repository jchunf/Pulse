import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("HandBalanceQueries — F-20 dual-hand keystroke balance")
struct HandBalanceQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var endingAt: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 18; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func insertKeyCode(into db: PulseDatabase, day: Date, keyCode: UInt16, count: Int) throws {
        let dayStart = utcCalendar.startOfDay(for: day)
        let dayEpoch = Int64(dayStart.timeIntervalSince1970)
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO day_key_codes (day, key_code, count) VALUES (?, ?, ?)
                """, arguments: [dayEpoch, Int64(keyCode), count])
        }
    }

    @Test("empty database returns zeros")
    func empty() throws {
        let (store, _) = try makeStore()
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.leftCount == 0)
        #expect(balance.rightCount == 0)
        #expect(balance.unclassifiedCount == 0)
        #expect(balance.classifiedTotal == 0)
        #expect(balance.grandTotal == 0)
    }

    @Test("F key (left) and J key (right) classified to correct hand")
    func basicSplit() throws {
        let (store, db) = try makeStore()
        try insertKeyCode(into: db, day: endingAt, keyCode: 3,  count: 100)  // F
        try insertKeyCode(into: db, day: endingAt, keyCode: 38, count: 80)   // J
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.leftCount == 100)
        #expect(balance.rightCount == 80)
        #expect(balance.classifiedTotal == 180)
        #expect(abs(balance.leftFraction - (100.0 / 180.0)) < 0.0001)
    }

    @Test("space (49) is classified as right hand")
    func spaceIsRight() throws {
        let (store, db) = try makeStore()
        try insertKeyCode(into: db, day: endingAt, keyCode: 49, count: 200)  // space
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.leftCount == 0)
        #expect(balance.rightCount == 200)
    }

    @Test("unmapped keycode falls into unclassified bucket")
    func unclassifiedBucket() throws {
        let (store, db) = try makeStore()
        // Keycode 122 is F1 — neither in leftHandKeycodes nor
        // rightHandKeycodes by design.
        try insertKeyCode(into: db, day: endingAt, keyCode: 122, count: 5)
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.leftCount == 0)
        #expect(balance.rightCount == 0)
        #expect(balance.unclassifiedCount == 5)
        // classifiedTotal excludes unclassified.
        #expect(balance.classifiedTotal == 0)
        #expect(balance.grandTotal == 5)
        // Fractions are 0/0 — return 0 not NaN.
        #expect(balance.leftFraction == 0)
        #expect(balance.rightFraction == 0)
    }

    @Test("counts sum across days inside the window")
    func multiDaySum() throws {
        let (store, db) = try makeStore()
        // F (left) on day 0 and day 3.
        try insertKeyCode(into: db, day: endingAt, keyCode: 3, count: 50)
        let earlier = utcCalendar.date(byAdding: .day, value: -3, to: endingAt)!
        try insertKeyCode(into: db, day: earlier, keyCode: 3, count: 30)
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.leftCount == 80)
    }

    @Test("activity outside the window is excluded")
    func windowed() throws {
        let (store, db) = try makeStore()
        let outOfWindow = utcCalendar.date(byAdding: .day, value: -30, to: endingAt)!
        try insertKeyCode(into: db, day: outOfWindow, keyCode: 3, count: 999)
        let balance = try store.handBalance(endingAt: endingAt, days: 7, calendar: utcCalendar)
        #expect(balance.classifiedTotal == 0)
    }

    @Test("classification covers all standard letter keys exactly once")
    func classificationCoverage() throws {
        // Make sure no key is double-counted (in both sets) and the
        // 26 letter keys are all classified.
        let letterKeycodes: [UInt16] = [
            0, 1, 2, 3, 5,            // A S D F G
            4, 38, 40, 37,            // H J K L
            6, 7, 8, 9, 11,           // Z X C V B
            12, 13, 14, 15, 17,       // Q W E R T
            16, 32, 34, 31, 35,       // Y U I O P
            45, 46                    // N M
        ]
        var inLeft = 0
        var inRight = 0
        var inBoth = 0
        for kc in letterKeycodes {
            let l = HandBalance.leftHandKeycodes.contains(kc)
            let r = HandBalance.rightHandKeycodes.contains(kc)
            if l && r { inBoth += 1 }
            if l { inLeft += 1 }
            if r { inRight += 1 }
        }
        #expect(inBoth == 0, "no letter keycode should be in both hands")
        #expect(inLeft + inRight == letterKeycodes.count, "every letter keycode should be classified")
    }
}

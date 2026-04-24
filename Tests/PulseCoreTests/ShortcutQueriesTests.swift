import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ShortcutQueries — top-N combo leaderboard (F-33)")
struct ShortcutQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insertSec(into db: PulseDatabase, second: Int64, combo: String, count: Int64) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO sec_shortcuts (ts_second, combo, count) VALUES (?, ?, ?)",
                arguments: [second, combo, count]
            )
        }
    }

    private func insertMin(into db: PulseDatabase, minute: Int64, combo: String, count: Int64) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_shortcuts (ts_minute, combo, count) VALUES (?, ?, ?)",
                arguments: [minute, combo, count]
            )
        }
    }

    private func insertHour(into db: PulseDatabase, hour: Int64, combo: String, count: Int64) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO hour_shortcuts (ts_hour, combo, count) VALUES (?, ?, ?)",
                arguments: [hour, combo, count]
            )
        }
    }

    @Test("empty DB returns empty list")
    func emptyDB() throws {
        let (store, _) = try makeStore()
        let rows = try store.shortcutLeaderboard(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600)
        )
        #expect(rows.isEmpty)
    }

    @Test("sums counts across all three layers per combo")
    func sumsAcrossLayers() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let startSec = Int64(dayStart.timeIntervalSince1970)
        // hour: cmd+c 50
        try insertHour(into: db, hour: startSec, combo: "cmd+c", count: 50)
        // min: cmd+c 10
        try insertMin(into: db, minute: startSec + 3_600, combo: "cmd+c", count: 10)
        // sec: cmd+c 3
        try insertSec(into: db, second: startSec + 7_200, combo: "cmd+c", count: 3)
        // Another combo: only in min layer
        try insertMin(into: db, minute: startSec + 3_660, combo: "cmd+v", count: 25)

        let rows = try store.shortcutLeaderboard(start: dayStart, end: dayEnd, limit: 5)
        #expect(rows.count == 2)
        #expect(rows[0].combo == "cmd+c")
        #expect(rows[0].count == 63)
        #expect(rows[1].combo == "cmd+v")
        #expect(rows[1].count == 25)
    }

    @Test("respects the limit")
    func respectsLimit() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let startSec = Int64(dayStart.timeIntervalSince1970)
        for idx in 0..<10 {
            try insertHour(into: db, hour: startSec, combo: "cmd+\(idx)", count: Int64(100 - idx))
        }
        let rows = try store.shortcutLeaderboard(
            start: dayStart,
            end: dayStart.addingTimeInterval(86_400),
            limit: 3
        )
        #expect(rows.count == 3)
        #expect(rows[0].combo == "cmd+0")   // count 100
        #expect(rows[1].combo == "cmd+1")
        #expect(rows[2].combo == "cmd+2")
    }

    @Test("ignores rows outside the window")
    func outOfWindow() throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let startSec = Int64(dayStart.timeIntervalSince1970)
        // Before window: ignored.
        try insertHour(into: db, hour: startSec - 3_600, combo: "cmd+c", count: 999)
        // In window.
        try insertHour(into: db, hour: startSec, combo: "cmd+v", count: 5)
        // After window: ignored (end-exclusive).
        try insertHour(into: db, hour: startSec + 86_400, combo: "cmd+x", count: 100)

        let rows = try store.shortcutLeaderboard(
            start: dayStart,
            end: dayStart.addingTimeInterval(86_400)
        )
        #expect(rows.count == 1)
        #expect(rows[0].combo == "cmd+v")
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("AppTransitionsQueries — F-13 Sankey aggregation")
struct AppTransitionsQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insertSwitch(into db: PulseDatabase, ts: Date, bundle: String) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [Int64(ts.timeIntervalSince1970 * 1_000), bundle]
            )
        }
    }

    private var anchor: Date {
        Date(timeIntervalSince1970: 1_776_000_000)
    }

    @Test("empty window returns no transitions")
    func emptyWindow() throws {
        let (store, _) = try makeStore()
        let result = try store.appTransitions(
            start: anchor,
            end: anchor.addingTimeInterval(3_600)
        )
        #expect(result.isEmpty)
    }

    @Test("single transition pair is counted")
    func singlePair() throws {
        let (store, db) = try makeStore()
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(60), bundle: "com.apple.Mail")

        let result = try store.appTransitions(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(120)
        )
        #expect(result.count == 1)
        #expect(result[0].fromBundle == "com.apple.Safari")
        #expect(result[0].toBundle == "com.apple.Mail")
        #expect(result[0].count == 1)
    }

    @Test("multiple of the same pair sum into one row")
    func pairSummed() throws {
        let (store, db) = try makeStore()
        // Safari → Mail twice, each with a different timestamp.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(30), bundle: "com.apple.Mail")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(60), bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(90), bundle: "com.apple.Mail")

        let result = try store.appTransitions(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(120)
        )
        // Safari→Mail: 2 transitions; Mail→Safari: 1 transition.
        #expect(result.count == 2)
        #expect(result[0].fromBundle == "com.apple.Safari")
        #expect(result[0].toBundle == "com.apple.Mail")
        #expect(result[0].count == 2)
        #expect(result[1].fromBundle == "com.apple.Mail")
        #expect(result[1].toBundle == "com.apple.Safari")
        #expect(result[1].count == 1)
    }

    @Test("self-transitions (A → A) are filtered out")
    func selfTransitionsExcluded() throws {
        let (store, db) = try makeStore()
        // Three Safari rows in a row (a UI duplicate-activation
        // scenario) — should produce zero transitions.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(10), bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(20), bundle: "com.apple.Safari")

        let result = try store.appTransitions(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(60)
        )
        #expect(result.isEmpty)
    }

    @Test("rows outside the window are excluded")
    func windowed() throws {
        let (store, db) = try makeStore()
        // In-window pair.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(30), bundle: "com.apple.Mail")
        // Out-of-window pair (1 hour later, after end).
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(7_200), bundle: "com.apple.Notes")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(7_300), bundle: "com.apple.Mail")

        let result = try store.appTransitions(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(60)
        )
        #expect(result.count == 1)
        #expect(result[0].fromBundle == "com.apple.Safari")
        #expect(result[0].toBundle == "com.apple.Mail")
    }

    @Test("limit caps the returned row count, ordered by count desc")
    func limitsApplied() throws {
        let (store, db) = try makeStore()
        // 5× alternating a/b → produces 5 a→b transitions and 4 b→a
        // transitions. With limit=1 we should get just the top one.
        var ts = anchor
        for _ in 0..<5 {
            try insertSwitch(into: db, ts: ts, bundle: "a")
            ts = ts.addingTimeInterval(1)
            try insertSwitch(into: db, ts: ts, bundle: "b")
            ts = ts.addingTimeInterval(1)
        }

        let result = try store.appTransitions(
            start: anchor.addingTimeInterval(-1),
            end: ts.addingTimeInterval(1),
            limit: 1
        )
        #expect(result.count == 1)
        #expect(result[0].fromBundle == "a")
        #expect(result[0].toBundle == "b")
        #expect(result[0].count == 5)
    }
}

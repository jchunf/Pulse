import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("ChaoticMomentQueries — F-21 busiest minute")
struct ChaoticMomentQueriesTests {

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

    /// Aligned to a 60-second boundary so test minutes don't depend on
    /// epoch-modulo arithmetic.
    private var anchor: Date {
        Date(timeIntervalSince1970: 1_776_000_000)
    }

    @Test("empty database returns nil")
    func empty() throws {
        let (store, _) = try makeStore()
        #expect(try store.busiestMultitaskingMinute(
            start: anchor,
            end: anchor.addingTimeInterval(3_600)
        ) == nil)
    }

    @Test("a single below-threshold minute returns nil")
    func belowThreshold() throws {
        let (store, db) = try makeStore()
        // Two switches in one minute — under the default threshold (3).
        try insertSwitch(into: db, ts: anchor, bundle: "a")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(10), bundle: "b")
        #expect(try store.busiestMultitaskingMinute(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(60)
        ) == nil)
    }

    @Test("picks the minute with the most switches")
    func pickBusiest() throws {
        let (store, db) = try makeStore()
        // Quiet minute 0 (2 switches) — below threshold.
        try insertSwitch(into: db, ts: anchor, bundle: "a")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(10), bundle: "b")
        // Busy minute 5 (4 switches across 4 distinct apps).
        let busyBase = anchor.addingTimeInterval(5 * 60)
        try insertSwitch(into: db, ts: busyBase, bundle: "x")
        try insertSwitch(into: db, ts: busyBase.addingTimeInterval(10), bundle: "y")
        try insertSwitch(into: db, ts: busyBase.addingTimeInterval(20), bundle: "z")
        try insertSwitch(into: db, ts: busyBase.addingTimeInterval(30), bundle: "w")

        let moment = try #require(try store.busiestMultitaskingMinute(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(3_600)
        ))
        #expect(moment.switchCount == 4)
        #expect(moment.bundles == ["w", "x", "y", "z"])
        #expect(moment.minuteStart == busyBase)
    }

    @Test("self-repeats are not filtered out — the metric is raw switch count")
    func selfRepeatsCounted() throws {
        let (store, db) = try makeStore()
        // Three Safari rows in a row — 3 switch *events* even though
        // they're all the same bundle. F-21 measures raw activity in
        // a minute, not unique apps; filtering self-repeats would
        // hide the case where the OS spammed activations.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(10), bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(20), bundle: "com.apple.Safari")

        let moment = try #require(try store.busiestMultitaskingMinute(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(60)
        ))
        #expect(moment.switchCount == 3)
        #expect(moment.bundles == ["com.apple.Safari"])
    }

    @Test("ties on count are broken by the later minute")
    func tieBreakLatest() throws {
        let (store, db) = try makeStore()
        // Two equally-busy minutes (3 each).
        for offset in [0, 10, 20] {
            try insertSwitch(into: db, ts: anchor.addingTimeInterval(TimeInterval(offset)),
                             bundle: "a\(offset)")
        }
        let later = anchor.addingTimeInterval(5 * 60)
        for offset in [0, 10, 20] {
            try insertSwitch(into: db, ts: later.addingTimeInterval(TimeInterval(offset)),
                             bundle: "b\(offset)")
        }
        let moment = try #require(try store.busiestMultitaskingMinute(
            start: anchor.addingTimeInterval(-1),
            end: later.addingTimeInterval(60)
        ))
        // Later minute wins.
        #expect(moment.minuteStart == later)
        #expect(moment.switchCount == 3)
    }
}

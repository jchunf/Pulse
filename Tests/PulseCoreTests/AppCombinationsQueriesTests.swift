import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("AppCombinationsQueries — F-14 work-stack aggregation")
struct AppCombinationsQueriesTests {

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
        // Aligned to a 10-minute boundary so the test buckets don't
        // depend on epoch-modulo arithmetic.
        Date(timeIntervalSince1970: 1_776_000_000)
    }

    @Test("empty database returns no combinations")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let result = try store.appCombinations(
            start: anchor,
            end: anchor.addingTimeInterval(3_600)
        )
        #expect(result.isEmpty)
    }

    @Test("single-app buckets are filtered (minSize defaults to 2)")
    func singletonsExcluded() throws {
        let (store, db) = try makeStore()
        // Three Safari rows in one 10-min bucket — should produce no
        // combination because the set size is 1.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(60), bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(120), bundle: "com.apple.Safari")

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(600)
        )
        #expect(result.isEmpty)
    }

    @Test("a single 2-app bucket yields one combination, occurrences = 1")
    func basicTwoAppCombo() throws {
        let (store, db) = try makeStore()
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(120), bundle: "com.apple.Mail")

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(600)
        )
        #expect(result.count == 1)
        #expect(result[0].bundles == ["com.apple.Mail", "com.apple.Safari"])
        #expect(result[0].occurrences == 1)
    }

    @Test("the same combination across many buckets sums into one row")
    func combinationSummed() throws {
        let (store, db) = try makeStore()
        // Three separate 10-min buckets, each with the same Safari +
        // Mail pair (in different order to prove set-equality).
        for bucket in 0..<3 {
            let base = anchor.addingTimeInterval(TimeInterval(bucket) * 600)
            try insertSwitch(into: db, ts: base.addingTimeInterval(60),
                             bundle: "com.apple.Safari")
            try insertSwitch(into: db, ts: base.addingTimeInterval(180),
                             bundle: "com.apple.Mail")
        }

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(3 * 600)
        )
        #expect(result.count == 1)
        #expect(result[0].bundles == ["com.apple.Mail", "com.apple.Safari"])
        #expect(result[0].occurrences == 3)
    }

    @Test("ranking puts more-frequent combinations first")
    func rankingByOccurrence() throws {
        let (store, db) = try makeStore()
        // Combo A (Mail + Safari) appears in 3 buckets.
        for bucket in 0..<3 {
            let base = anchor.addingTimeInterval(TimeInterval(bucket) * 600)
            try insertSwitch(into: db, ts: base.addingTimeInterval(60),
                             bundle: "com.apple.Mail")
            try insertSwitch(into: db, ts: base.addingTimeInterval(120),
                             bundle: "com.apple.Safari")
        }
        // Combo B (Notes + Calendar) appears in 1 bucket, well after.
        let later = anchor.addingTimeInterval(10 * 600)
        try insertSwitch(into: db, ts: later, bundle: "com.apple.Notes")
        try insertSwitch(into: db, ts: later.addingTimeInterval(60),
                         bundle: "com.apple.Calendar")

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: later.addingTimeInterval(600)
        )
        #expect(result.count == 2)
        #expect(result[0].bundles == ["com.apple.Mail", "com.apple.Safari"])
        #expect(result[0].occurrences == 3)
        #expect(result[1].bundles == ["com.apple.Calendar", "com.apple.Notes"])
        #expect(result[1].occurrences == 1)
    }

    @Test("limit truncates the result list, ordered by occurrences desc")
    func limitTruncates() throws {
        let (store, db) = try makeStore()
        // 4 distinct two-app combos with 4, 3, 2, 1 occurrences each.
        let combos: [(String, String, Int)] = [
            ("a.b", "a.c", 4),
            ("a.d", "a.e", 3),
            ("a.f", "a.g", 2),
            ("a.h", "a.i", 1)
        ]
        var bucketIndex = 0
        for (left, right, count) in combos {
            for _ in 0..<count {
                let base = anchor.addingTimeInterval(TimeInterval(bucketIndex) * 600)
                try insertSwitch(into: db, ts: base, bundle: left)
                try insertSwitch(into: db, ts: base.addingTimeInterval(60), bundle: right)
                bucketIndex += 1
            }
        }

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(TimeInterval(bucketIndex) * 600 + 60),
            limit: 2
        )
        #expect(result.count == 2)
        #expect(result.map(\.occurrences) == [4, 3])
    }

    @Test("activity outside the window is ignored")
    func windowing() throws {
        let (store, db) = try makeStore()
        // In-window pair.
        try insertSwitch(into: db, ts: anchor, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: anchor.addingTimeInterval(120),
                         bundle: "com.apple.Mail")
        // Out-of-window pair (another bucket, far later).
        let outside = anchor.addingTimeInterval(7_200)
        try insertSwitch(into: db, ts: outside, bundle: "com.apple.Notes")
        try insertSwitch(into: db, ts: outside.addingTimeInterval(60),
                         bundle: "com.apple.Calendar")

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(600)
        )
        #expect(result.count == 1)
        #expect(result[0].bundles == ["com.apple.Mail", "com.apple.Safari"])
    }

    @Test("a four-app stack survives as a single combination")
    func fourAppStack() throws {
        let (store, db) = try makeStore()
        // VSCode + Chrome + Terminal + Slack — the canonical "coding
        // session" stack, all in the same 10-minute bucket.
        let bundles = [
            "com.microsoft.VSCode",
            "com.google.Chrome",
            "com.apple.Terminal",
            "com.tinyspeck.slackmacgap"
        ]
        for (i, bundle) in bundles.enumerated() {
            try insertSwitch(
                into: db,
                ts: anchor.addingTimeInterval(TimeInterval(i) * 30),
                bundle: bundle
            )
        }

        let result = try store.appCombinations(
            start: anchor.addingTimeInterval(-1),
            end: anchor.addingTimeInterval(600)
        )
        #expect(result.count == 1)
        #expect(result[0].bundles == bundles.sorted())
        #expect(result[0].occurrences == 1)
    }
}

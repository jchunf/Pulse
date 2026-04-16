import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

/// Performance regression guard rails. Targets pulled from
/// `docs/10-testing-and-ci.md#五`. Disabled by default so PR CI stays fast;
/// the `nightly.yml` workflow sets `PULSE_RUN_BENCHMARKS=1` to opt in.
@Suite(
    "Writer / rollup performance benchmarks",
    .enabled(if: ProcessInfo.processInfo.environment["PULSE_RUN_BENCHMARKS"] != nil)
)
struct WriterBenchmarks {

    @Test(
        "ingest 10k mouse moves and flush in well under 5s",
        .timeLimit(.minutes(1))
    )
    func ingest10kMoves() async throws {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let displays: @Sendable () -> [DisplayInfo] = { [] }
        let writer = EventWriter(
            store: store,
            displayProvider: displays,
            flushInterval: 1,
            maxBufferedEvents: 20_000
        )
        let started = Date()
        let point = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        for i in 0..<10_000 {
            let ts = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 0.001)
            _ = await writer.enqueue(.mouseMove(point, at: ts))
        }
        await writer.flush()
        let elapsed = Date().timeIntervalSince(started)
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 10_000)
        #expect(elapsed < 5.0, "10k inserts should take well under 5 seconds; was \(elapsed)s")
    }

    @Test(
        "rolling raw → second on 10k moves spread across 100 seconds is fast",
        .timeLimit(.minutes(1))
    )
    func rollupOf10kMoves() throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let db = try PulseDatabase.inMemory()
        try db.queue.write { db in
            for i in 0..<10_000 {
                // 100 seconds of moves at ~100 events/sec.
                let ts = Int64((1_700_000_000 + Double(i) * 0.01) * 1_000)
                try db.execute(
                    sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 1, 0.5, 0.5)",
                    arguments: [ts]
                )
            }
        }
        let scheduler = RollupScheduler(database: db, clock: clock)
        clock.advance(200)
        let started = Date()
        try scheduler.runOnce(.rawToSecond, now: clock.now)
        let elapsed = Date().timeIntervalSince(started)
        let secCount = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_mouse") ?? 0
        }
        #expect(secCount == 100)
        #expect(elapsed < 2.0, "rollup of 10k → 100 buckets should be fast; was \(elapsed)s")
    }
}


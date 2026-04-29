import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

/// Performance regression guard rails. Targets pulled from
/// `docs/10-testing-and-ci.md#五`. Disabled by default so PR CI stays fast;
/// the `nightly.yml` workflow sets `PULSE_RUN_BENCHMARKS=1` to opt in.
///
/// **Threshold philosophy**: these are *order-of-magnitude regression*
/// catchers, not micro-benchmarks. They're calibrated against the
/// shared GHA macos-15 runner, which has notable variance — a slow
/// neighbour or cold dyld cache can stretch a "10k mouse moves"
/// scenario far beyond what local-Mac timing would suggest. The
/// budgets below have ~3-4× headroom over a fast run so transient
/// runner load doesn't turn nightly red. If a real regression takes
/// the elapsed past these limits, that's a > 2× slowdown — far above
/// any cooperative-task / actor-hop noise — and worth investigating.
@Suite(
    "Writer / rollup performance benchmarks",
    .enabled(if: ProcessInfo.processInfo.environment["PULSE_RUN_BENCHMARKS"] != nil)
)
struct WriterBenchmarks {

    @Test(
        "ingest 10k mouse moves and flush within the runner-variance budget",
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
        // Local Macs land around 1-2s. The 12s budget is calibrated for
        // the GHA macos-15 shared runner: PR #94/#95 expanded the
        // `EventWriter` actor with shortcut + keycode buffers, which
        // bumped per-`enqueue` actor-hop overhead just enough that the
        // previous 5s budget started catching shared-runner tail latency
        // rather than real regressions (see nightly #9-#13).
        #expect(elapsed < 12.0, "10k inserts: \(elapsed)s (budget 12s)")
    }

    @Test(
        "rolling raw → second on 10k moves spread across 100 seconds within the runner-variance budget",
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
        // Local Macs land around 0.3-0.5s. 5s budget = ~10× headroom
        // for shared-runner SQLite tail latency.
        #expect(elapsed < 5.0, "rollup of 10k → 100 buckets: \(elapsed)s (budget 5s)")
    }
}


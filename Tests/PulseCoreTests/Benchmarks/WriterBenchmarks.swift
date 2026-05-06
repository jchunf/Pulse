import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

/// Performance regression guard rails. Disabled by default so PR CI
/// stays fast; the `nightly.yml` workflow sets
/// `PULSE_RUN_BENCHMARKS=1` to opt in.
///
/// **What we test vs what we don't:**
///
/// - **Correctness** (`#expect(counts == ...)`): hard-gated. The
///   benchmark is meaningless if the events aren't actually written.
/// - **Timing** (`print(...)`): logged but **not** gated. PR #141
///   already widened budgets to 12s / 5s and nightly still red-flagged
///   regularly — the GHA macos-15 shared runner has tail latency that
///   makes any hard timing assertion inherently flaky. Surfacing
///   numbers in the log lets a human eyeball the trend without
///   nightly going red on every slow neighbour.
///
/// To recover a hard regression gate later, reintroduce the
/// `#expect(elapsed < ...)` line with a generous-but-meaningful
/// budget — but only after a few weeks of data on what the actual
/// runner-side numbers look like, sourced from these `print` lines.
@Suite(
    "Writer / rollup performance benchmarks",
    .enabled(if: ProcessInfo.processInfo.environment["PULSE_RUN_BENCHMARKS"] != nil)
)
struct WriterBenchmarks {

    @Test(
        "ingest 10k mouse moves and flush",
        .timeLimit(.minutes(2))
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
        // Logged for trend-watching, deliberately not gated.
        // Local Macs land around 1-2s; shared GHA runners have run
        // 5s-15s+ depending on neighbour load.
        print("BENCHMARK ingest10kMoves elapsed=\(elapsed)s")
    }

    @Test(
        "rolling raw → second on 10k moves spread across 100 seconds",
        .timeLimit(.minutes(2))
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
        // Logged, not gated. Local Macs ~ 0.3-0.5s.
        print("BENCHMARK rollupOf10kMoves elapsed=\(elapsed)s")
    }
}


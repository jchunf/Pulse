import Foundation
import GRDB

/// F-26 — walks today's `idle_entered` / `idle_exited` pairs in
/// `system_events` and returns every completed rest segment plus
/// derived stats (count, total, longest). The IdleDetector emits
/// `idle_entered` only after its ~5-minute threshold crosses, so a
/// segment here represents **time-past-threshold**, not the full
/// no-event window. That keeps the sum consistent with
/// `hour_summary.idle_seconds` (the A15 "Idle today" card) rather
/// than diverging by `5 * segmentCount` minutes.
///
/// Edge cases handled:
///
/// - A rest still open at `capUntil` (ongoing idle — no `idle_exited`
///   yet) closes at `capUntil`, so today's partial rest shows up
///   live on the Dashboard instead of waiting for the user to wake
///   up the machine.
/// - An `idle_entered` carried over from yesterday (no matching
///   start in today's window) is ignored — the segment belongs to
///   yesterday.
/// - An orphaned `idle_exited` with no preceding `idle_entered`
///   today is dropped.
public extension EventStore {

    func restSegments(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> RestDay {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        guard endCap > dayStart else { return RestDay(segments: []) }

        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endCap.timeIntervalSince1970 * 1_000)

        let rows = try database.queue.read { db -> [(Int64, String)] in
            try Row.fetchAll(db, sql: """
                SELECT ts, category FROM system_events
                WHERE category IN ('idle_entered', 'idle_exited')
                  AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [startMs, endMs]).map { row in
                (row["ts"] as Int64, row["category"] as String)
            }
        }

        var segments: [RestSegment] = []
        var openStart: Date? = nil
        for (tsMs, category) in rows {
            let instant = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0)
            switch category {
            case "idle_entered":
                // Two `idle_entered` in a row (no exit between) means
                // we lost the paired exit — treat the newer one as
                // authoritative and drop the stale openStart.
                openStart = instant
            case "idle_exited":
                if let start = openStart, instant > start {
                    segments.append(RestSegment(startedAt: start, endedAt: instant))
                }
                openStart = nil
            default:
                break
            }
        }

        // If idle is still open at capUntil, close the segment there
        // so the UI can show the partial rest live.
        if let start = openStart, endCap > start {
            segments.append(RestSegment(startedAt: start, endedAt: endCap))
        }

        return RestDay(segments: segments)
    }
}

// MARK: - Value types

public struct RestSegment: Sendable, Equatable {
    public let startedAt: Date
    public let endedAt: Date

    public init(startedAt: Date, endedAt: Date) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var durationSeconds: Int {
        Int(endedAt.timeIntervalSince(startedAt))
    }
}

/// A day's rest recap. Empty-array is a legitimate result (no rests
/// recorded today) and every derived stat collapses to zero — no
/// optional chaining required at the call site.
public struct RestDay: Sendable, Equatable {
    public let segments: [RestSegment]

    public init(segments: [RestSegment]) {
        self.segments = segments
    }

    public var count: Int { segments.count }

    public var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    public var longestSeconds: Int {
        segments.map(\.durationSeconds).max() ?? 0
    }
}

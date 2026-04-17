import Foundation
import GRDB

/// A statistical read on the user's session rhythm for a single day,
/// derived from the same `system_events.foreground_app` stream that
/// powers `longestFocusSegment`. Review §3.6 calls out
/// "are you a 5-minute-per-jump checker or a 40-minute deep worker"
/// as the most interesting kind of self-knowledge Pulse can surface,
/// and this is the minimum-viable read of that.
///
/// A **session** here is a single contiguous foreground-app interval
/// that lasts at least `minSessionSeconds` seconds. Cross-app switches
/// split sessions; short dips (<1 min) don't get counted at all. This
/// matches how most users informally think about "one thing" — you
/// stopped being in that thing the moment you switched away.
public struct SessionPosture: Sendable, Equatable {
    public let sessionCount: Int
    public let averageDurationSeconds: Int
    public let medianDurationSeconds: Int
    public let longestDurationSeconds: Int
    public let shortestDurationSeconds: Int

    public init(
        sessionCount: Int,
        averageDurationSeconds: Int,
        medianDurationSeconds: Int,
        longestDurationSeconds: Int,
        shortestDurationSeconds: Int
    ) {
        self.sessionCount = sessionCount
        self.averageDurationSeconds = averageDurationSeconds
        self.medianDurationSeconds = medianDurationSeconds
        self.longestDurationSeconds = longestDurationSeconds
        self.shortestDurationSeconds = shortestDurationSeconds
    }

    public static let empty = SessionPosture(
        sessionCount: 0,
        averageDurationSeconds: 0,
        medianDurationSeconds: 0,
        longestDurationSeconds: 0,
        shortestDurationSeconds: 0
    )

    /// Derives posture stats from a list of interval durations in
    /// seconds. Pure so it can be tested without a database. The input
    /// does not need to be sorted.
    public static func from(durationsSeconds raw: [Int]) -> SessionPosture {
        guard !raw.isEmpty else { return .empty }
        let sorted = raw.sorted()
        let total = sorted.reduce(0, +)
        let count = sorted.count
        let average = total / count
        let median: Int
        if count % 2 == 1 {
            median = sorted[count / 2]
        } else {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return SessionPosture(
            sessionCount: count,
            averageDurationSeconds: average,
            medianDurationSeconds: median,
            longestDurationSeconds: sorted.last ?? 0,
            shortestDurationSeconds: sorted.first ?? 0
        )
    }
}

public extension EventStore {

    /// Computes `SessionPosture` for `day`, treating every foreground-app
    /// interval ≥ `minSessionSeconds` as one session. Uses the same
    /// carry-over-from-yesterday + cap-at-now logic as
    /// `longestFocusSegment`, so intervals are consistent across the
    /// two surfaces.
    func sessionPosture(
        on day: Date,
        minSessionSeconds: Int = 60,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> SessionPosture {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart, now)
        guard dayEnd > dayStart else { return .empty }
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let dayEndMs = Int64(dayEnd.timeIntervalSince1970 * 1_000)

        return try database.queue.read { db -> SessionPosture in
            let priorBundle = try String.fetchOne(db, sql: """
                SELECT payload FROM system_events
                WHERE category = 'foreground_app' AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [dayStartMs])

            let transitions = try Row.fetchAll(db, sql: """
                SELECT ts FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [dayStartMs, dayEndMs])

            var durations: [Int] = []
            var currentStart = dayStartMs
            var hasCurrentBundle = priorBundle != nil
            for row in transitions {
                let ts: Int64 = row["ts"]
                if hasCurrentBundle, ts > currentStart {
                    let secs = Int((ts - currentStart) / 1_000)
                    if secs >= minSessionSeconds {
                        durations.append(secs)
                    }
                }
                currentStart = ts
                hasCurrentBundle = true
            }
            if hasCurrentBundle, dayEndMs > currentStart {
                let secs = Int((dayEndMs - currentStart) / 1_000)
                if secs >= minSessionSeconds {
                    durations.append(secs)
                }
            }

            return SessionPosture.from(durationsSeconds: durations)
        }
    }
}

import Foundation
import GRDB

/// F-13 — read-side aggregation that counts foreground-app transitions
/// (`from → to`) inside a window. Pulls from `system_events.foreground_app`
/// (the same point-event source `appSwitchCount` and `longestFocusSegment`
/// already use); a SQL `LEAD()` window over events ordered by timestamp
/// pairs each row with its successor, and a `GROUP BY (from, to)` rolls
/// the pairs up into a transition count.
///
/// The Sankey card renders this directly: source bundles on the left,
/// target bundles on the right, ribbon widths proportional to `count`.
/// No new collector or migration required — `system_events` is already
/// the canonical event log.
public extension EventStore {

    /// Returns the top `limit` `(fromBundle, toBundle, count)` pairs in
    /// the window `[start, end)`. Pairs are ordered by `count` descending,
    /// ties broken by `fromBundle` then `toBundle` for determinism.
    ///
    /// Self-transitions (a → a, which mostly come from rapid double-
    /// activations of the same app) are filtered out — they're noise
    /// in a flow diagram.
    func appTransitions(
        start: Date,
        end: Date,
        limit: Int = 12
    ) throws -> [AppTransition] {
        precondition(limit >= 1, "limit must be positive")
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        guard endMs > startMs else { return [] }

        return try database.queue.read { db -> [AppTransition] in
            try Row.fetchAll(db, sql: """
                WITH ordered AS (
                    SELECT
                        ts,
                        payload AS bundle_id,
                        LEAD(payload) OVER (ORDER BY ts) AS next_bundle_id
                    FROM system_events
                    WHERE category = 'foreground_app'
                      AND ts >= ? AND ts < ?
                )
                SELECT
                    bundle_id      AS from_bundle,
                    next_bundle_id AS to_bundle,
                    COUNT(*)       AS hits
                FROM ordered
                WHERE next_bundle_id IS NOT NULL
                  AND next_bundle_id != bundle_id
                GROUP BY bundle_id, next_bundle_id
                ORDER BY hits DESC, bundle_id ASC, next_bundle_id ASC
                LIMIT ?
                """, arguments: [startMs, endMs, limit])
                .map { row in
                    AppTransition(
                        fromBundle: row["from_bundle"] ?? "",
                        toBundle: row["to_bundle"] ?? "",
                        count: row["hits"] ?? 0
                    )
                }
        }
    }
}

/// One `from → to` foreground-app transition with its observed count
/// over the queried window. Used by the Sankey card.
public struct AppTransition: Sendable, Equatable, Identifiable {
    public let fromBundle: String
    public let toBundle: String
    public let count: Int

    public var id: String { "\(fromBundle)→\(toBundle)" }

    public init(fromBundle: String, toBundle: String, count: Int) {
        self.fromBundle = fromBundle
        self.toBundle = toBundle
        self.count = count
    }
}

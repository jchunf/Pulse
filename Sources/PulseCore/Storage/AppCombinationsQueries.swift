import Foundation
import GRDB

/// F-14 — read-side aggregation that identifies recurring "work stacks":
/// sets of foreground apps that you consistently bounce between in the
/// same time window. The classic example is `VSCode + Chrome + Terminal
/// + Slack` co-appearing inside the same 10-minute slice — that's a
/// programming session. `Mail + Calendar` is communication. `Music +
/// Browser` is "consuming media".
///
/// Algorithm: bucket time into `bucketSeconds`-wide windows; for each
/// window collect the *set* of distinct foreground apps observed; group
/// windows by set; rank by occurrence count. The aggregation runs in
/// Swift rather than SQL so the dedup happens against a real `Set`
/// (SQLite's `GROUP_CONCAT` doesn't sort by default, which would split
/// `{A,B}` and `{B,A}` into separate buckets).
public extension EventStore {

    /// Returns the top `limit` recurring app combinations inside
    /// `[start, end)`. Sets smaller than `minSize` are skipped (a
    /// 10-minute slot with one app isn't a "stack"). Each combination's
    /// `bundles` are sorted by bundle id for stable rendering and
    /// equality.
    func appCombinations(
        start: Date,
        end: Date,
        bucketSeconds: Int = 600,
        minSize: Int = 2,
        limit: Int = 8
    ) throws -> [AppCombination] {
        precondition(bucketSeconds >= 1, "bucketSeconds must be positive")
        precondition(minSize >= 2, "minSize must be at least 2 — singletons are not stacks")
        precondition(limit >= 1, "limit must be positive")
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        let bucketMs = Int64(bucketSeconds * 1_000)
        guard endMs > startMs else { return [] }

        // Pull distinct (bucket, bundle) pairs straight out of
        // `system_events`. The `DISTINCT` step is on the SQL side
        // because the per-bucket dedup is cheap there and reduces the
        // row count flowing into Swift.
        let pairs: [(Int64, String)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    ts / ? AS bucket,
                    payload AS bundle_id
                FROM system_events
                WHERE category = 'foreground_app'
                  AND ts >= ? AND ts < ?
                """, arguments: [bucketMs, startMs, endMs])
                .compactMap { row in
                    let bucket: Int64 = row["bucket"]
                    guard let bundle: String = row["bundle_id"] else { return nil }
                    return (bucket, bundle)
                }
        }

        // Group bundles by bucket.
        var bucketSets: [Int64: Set<String>] = [:]
        for (bucket, bundle) in pairs {
            bucketSets[bucket, default: []].insert(bundle)
        }

        // Count occurrences of each (sorted) combination.
        var counts: [String: (bundles: [String], count: Int)] = [:]
        for set in bucketSets.values {
            guard set.count >= minSize else { continue }
            let sortedBundles = set.sorted()
            let key = sortedBundles.joined(separator: "|")
            counts[key, default: (sortedBundles, 0)].count += 1
        }

        return counts.values
            .map { AppCombination(bundles: $0.bundles, occurrences: $0.count) }
            // Most-frequent first; ties broken by larger sets first
            // (a 4-app stack appearing 3× is more interesting than a
            // 2-app pair appearing 3×) and then alphabetically by id.
            .sorted { lhs, rhs in
                if lhs.occurrences != rhs.occurrences { return lhs.occurrences > rhs.occurrences }
                if lhs.bundles.count != rhs.bundles.count { return lhs.bundles.count > rhs.bundles.count }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }
}

/// One recurring set of foreground apps with the number of windows
/// during which the *exact same set* was observed. Used by the F-14
/// "work stack" card.
public struct AppCombination: Sendable, Equatable, Identifiable {
    /// Bundle ids in this combination, sorted ascending for stable
    /// equality + deterministic rendering.
    public let bundles: [String]
    /// Number of buckets (default 10-minute) during which this exact
    /// set of apps was foreground at some point.
    public let occurrences: Int

    public var id: String { bundles.joined(separator: "|") }

    public init(bundles: [String], occurrences: Int) {
        self.bundles = bundles
        self.occurrences = occurrences
    }
}

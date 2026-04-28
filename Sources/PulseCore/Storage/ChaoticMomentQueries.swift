import Foundation
import GRDB

/// F-21 — picks the single 60-second window inside `[start, end)` that
/// contains the most `foreground_app` switches, plus the distinct apps
/// involved. The "most chaotic moment" of the day — useful as a one-
/// number "how scattered was I in my busiest minute?" call-out.
///
/// Source: `system_events.foreground_app` (the same point-event log F-13
/// + F-14 read from). Returns `nil` when no minute crosses the
/// `minSwitches` threshold (defaults to 3 — fewer than that doesn't
/// read as "chaotic" enough to call out).
public extension EventStore {

    func busiestMultitaskingMinute(
        start: Date,
        end: Date,
        minSwitches: Int = 3
    ) throws -> ChaoticMoment? {
        precondition(minSwitches >= 2, "minSwitches must be at least 2")
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        guard endMs > startMs else { return nil }

        return try database.queue.read { db -> ChaoticMoment? in
            // Group by minute (ms / 60_000), pick the row with the most
            // switches. Ties broken by latest minute so the card
            // surfaces the most recent peak (most actionable for
            // the user).
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                    ts / 60000 AS minute,
                    COUNT(*) AS switches
                FROM system_events
                WHERE category = 'foreground_app'
                  AND ts >= ? AND ts < ?
                GROUP BY minute
                HAVING switches >= ?
                ORDER BY switches DESC, minute DESC
                LIMIT 1
                """, arguments: [startMs, endMs, minSwitches])
            else { return nil }

            let minute: Int64 = row["minute"]
            let switches: Int64 = row["switches"]
            let minuteStartMs = minute * 60_000
            let minuteEndMs = minuteStartMs + 60_000

            // Pull the distinct bundle ids for that minute. SQLite's
            // GROUP_CONCAT isn't sorted, so we fetch + sort in Swift.
            let bundleRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT payload AS bundle_id
                FROM system_events
                WHERE category = 'foreground_app'
                  AND ts >= ? AND ts < ?
                """, arguments: [minuteStartMs, minuteEndMs])
            let bundles = bundleRows
                .compactMap { $0["bundle_id"] as String? }
                .sorted()

            return ChaoticMoment(
                minuteStart: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
                switchCount: Int(switches),
                bundles: bundles
            )
        }
    }
}

/// One "busiest minute" snapshot. `bundles` are the distinct foreground
/// apps that appeared during that minute, sorted ascending for stable
/// rendering.
public struct ChaoticMoment: Sendable, Equatable {
    public let minuteStart: Date
    public let switchCount: Int
    public let bundles: [String]

    public init(minuteStart: Date, switchCount: Int, bundles: [String]) {
        self.minuteStart = minuteStart
        self.switchCount = switchCount
        self.bundles = bundles
    }
}

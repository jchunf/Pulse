import Foundation
import GRDB

/// F-33 — Dashboard top-N shortcut usage. Layering is the same three-
/// tier UNION pattern `todaySummary` uses: for any given (day, combo)
/// pair the counts live in exactly one of `hour_shortcuts` /
/// `min_shortcuts` / `sec_shortcuts` at a time, so summing across all
/// three is correct regardless of where the rollup boundary sits.
public extension EventStore {

    /// Top-N most-used shortcut combos in `[start, end)`. Returns rows
    /// sorted by descending count, combos with zero counts excluded.
    func shortcutLeaderboard(
        start: Date,
        end: Date,
        limit: Int = 5
    ) throws -> [ShortcutUsageRow] {
        let startSec = Int64(start.timeIntervalSince1970)
        let endSec = Int64(end.timeIntervalSince1970)
        guard endSec > startSec else { return [] }

        return try database.queue.read { db -> [ShortcutUsageRow] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT combo, SUM(total) AS total FROM (
                    SELECT combo, SUM(count) AS total FROM hour_shortcuts
                    WHERE ts_hour >= ? AND ts_hour < ?
                    GROUP BY combo
                    UNION ALL
                    SELECT combo, SUM(count) AS total FROM min_shortcuts
                    WHERE ts_minute >= ? AND ts_minute < ?
                    GROUP BY combo
                    UNION ALL
                    SELECT combo, SUM(count) AS total FROM sec_shortcuts
                    WHERE ts_second >= ? AND ts_second < ?
                    GROUP BY combo
                )
                GROUP BY combo
                HAVING total > 0
                ORDER BY total DESC, combo ASC
                LIMIT ?
                """, arguments: [
                    startSec, endSec,
                    startSec, endSec,
                    startSec, endSec,
                    limit
                ])
            return rows.map { row in
                ShortcutUsageRow(
                    combo: row["combo"] as String,
                    count: row["total"] as Int
                )
            }
        }
    }
}

public struct ShortcutUsageRow: Sendable, Equatable, Identifiable {
    public let combo: String
    public let count: Int

    public var id: String { combo }

    public init(combo: String, count: Int) {
        self.combo = combo
        self.count = count
    }
}

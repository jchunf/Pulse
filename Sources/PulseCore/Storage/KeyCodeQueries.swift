import Foundation
import GRDB

/// F-08 — reads `day_key_codes` to produce a per-keycode total over
/// the last N local days. Used by the keyboard-heatmap card.
public extension EventStore {

    /// Sum of `count` per `key_code` over the `days` most recent
    /// local days (the day containing `endingAt` counts as day 0,
    /// i.e. the most recent local day up to `endingAt`). Rows for
    /// keyCodes absent from the ladder are included — the view
    /// layer decides which keys to render.
    func keyCodeDistribution(
        endingAt: Date,
        days: Int,
        calendar: Calendar = .current
    ) throws -> [KeyCodeCount] {
        precondition(days > 0, "days must be > 0")
        let dayStart = calendar.startOfDay(for: endingAt)
        let localOffset = Int64(calendar.timeZone.secondsFromGMT(for: dayStart))
        let startDay = Int64(dayStart.timeIntervalSince1970) - Int64(days - 1) * 86_400
        let endDayExclusive = Int64(dayStart.timeIntervalSince1970) + 86_400
        _ = localOffset  // offset-of-day is already folded into `day` rows at write time.

        return try database.queue.read { db -> [KeyCodeCount] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT key_code, SUM(count) AS total
                FROM day_key_codes
                WHERE day >= ? AND day < ?
                GROUP BY key_code
                HAVING total > 0
                ORDER BY total DESC, key_code ASC
                """, arguments: [startDay, endDayExclusive])
            return rows.map { row in
                KeyCodeCount(
                    keyCode: UInt16(truncatingIfNeeded: row["key_code"] as Int64),
                    count: row["total"] as Int
                )
            }
        }
    }
}

public struct KeyCodeCount: Sendable, Equatable, Identifiable {
    public let keyCode: UInt16
    public let count: Int

    public var id: UInt16 { keyCode }

    public init(keyCode: UInt16, count: Int) {
        self.keyCode = keyCode
        self.count = count
    }
}

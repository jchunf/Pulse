import Foundation
import GRDB

/// F-20 — left-vs-right-hand keystroke balance, derived from
/// `day_key_codes`. Pure read-side aggregation over the existing
/// V6 table; no new collector or migration. The classification is
/// the standard touch-typing convention for US-QWERTY: each keycode
/// is assigned to whichever hand normally hits it.
///
/// Hidden when keycode capture is opted out (`day_key_codes` is
/// empty for the user). Auto-hides at the model layer below a small
/// threshold so a few-press fluke doesn't read as "you favour
/// right hand 100%".
public extension EventStore {

    func handBalance(
        endingAt: Date,
        days: Int = 7,
        calendar: Calendar = .current
    ) throws -> HandBalance {
        precondition(days > 0, "days must be > 0")
        let dayStart = calendar.startOfDay(for: endingAt)
        let startDay = Int64(dayStart.timeIntervalSince1970) - Int64(days - 1) * 86_400
        let endDayExclusive = Int64(dayStart.timeIntervalSince1970) + 86_400

        let rows: [(UInt16, Int)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT key_code, SUM(count) AS total
                FROM day_key_codes
                WHERE day >= ? AND day < ?
                GROUP BY key_code
                HAVING total > 0
                """, arguments: [startDay, endDayExclusive])
                .map { row in
                    let kc = UInt16(truncatingIfNeeded: row["key_code"] as Int64)
                    let total: Int = row["total"]
                    return (kc, total)
                }
        }

        var leftCount: Int64 = 0
        var rightCount: Int64 = 0
        var unclassifiedCount: Int64 = 0
        for (kc, count) in rows {
            if HandBalance.leftHandKeycodes.contains(kc) {
                leftCount &+= Int64(count)
            } else if HandBalance.rightHandKeycodes.contains(kc) {
                rightCount &+= Int64(count)
            } else {
                // Modifiers, function keys, numpad, arrow keys —
                // ambiguous or symmetric. Tracked separately so a
                // future card can surface them; current UI ignores.
                unclassifiedCount &+= Int64(count)
            }
        }

        return HandBalance(
            leftCount: leftCount,
            rightCount: rightCount,
            unclassifiedCount: unclassifiedCount,
            windowDays: days
        )
    }
}

/// One window's left/right keystroke totals. The `unclassified`
/// bucket holds keys that don't cleanly map to one hand (modifiers,
/// arrows, numpad, function keys) so the visible balance ratio is
/// computed only over keys whose hand is unambiguous.
public struct HandBalance: Sendable, Equatable {
    public let leftCount: Int64
    public let rightCount: Int64
    public let unclassifiedCount: Int64
    public let windowDays: Int

    public init(
        leftCount: Int64,
        rightCount: Int64,
        unclassifiedCount: Int64,
        windowDays: Int
    ) {
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.unclassifiedCount = unclassifiedCount
        self.windowDays = windowDays
    }

    /// Total classified keystrokes (left + right). Excludes the
    /// unclassified bucket so the ratio reflects "of the keys
    /// you pressed where I know which hand hit them".
    public var classifiedTotal: Int64 { leftCount + rightCount }

    /// All keystrokes including unclassified — used for the
    /// "is there enough data to be meaningful" threshold check.
    public var grandTotal: Int64 { leftCount + rightCount + unclassifiedCount }

    /// Fraction of *classified* keys that the left hand pressed,
    /// 0…1. Returns 0 when the window has no classified activity.
    public var leftFraction: Double {
        classifiedTotal > 0 ? Double(leftCount) / Double(classifiedTotal) : 0
    }

    public var rightFraction: Double {
        classifiedTotal > 0 ? Double(rightCount) / Double(classifiedTotal) : 0
    }

    // MARK: - Hand classification (US-QWERTY touch-typing convention)

    /// Keycodes the left hand normally hits in standard touch-typing
    /// position. `Set` literal for O(1) lookup. Indexed against the
    /// same `keyCode` constants the F-08 keyboard heatmap uses
    /// (see `KeyboardHeatmapCard.rows`).
    static let leftHandKeycodes: Set<UInt16> = [
        // Top row: ` 1 2 3 4 5
        50, 18, 19, 20, 21, 23,
        // QWERT row + tab
        48, 12, 13, 14, 15, 17,
        // ASDFG row
        0, 1, 2, 3, 5,
        // ZXCVB row
        6, 7, 8, 9, 11
    ]

    /// Keycodes the right hand normally hits. Space (49) is included
    /// because most touch typists use the right thumb.
    static let rightHandKeycodes: Set<UInt16> = [
        // Top row: 6 7 8 9 0 - = backspace
        22, 26, 28, 25, 29, 27, 24, 51,
        // YUIOP row + brackets + backslash
        16, 32, 34, 31, 35, 33, 30, 42,
        // HJKL row + ;'⏎
        4, 38, 40, 37, 41, 39, 36,
        // NM,./ row
        45, 46, 43, 47, 44,
        // Space (right-thumb convention)
        49
    ]
}

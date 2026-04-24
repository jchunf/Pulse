import Foundation
import GRDB

/// Backs F-12 — the Dashboard's KPM-peak card. Returns the busiest
/// *minute* of typing in a given day. Layering mirrors `todaySummary`:
/// `min_key` carries today's already-rolled minutes (unaffected by the
/// current minute, because `rollSecondToMinute` only promotes closed
/// minutes), and `sec_key` carries the un-promoted tail which may still
/// include the current minute in progress.
///
/// The current-minute partial is returned as-is — it still reflects
/// "what did you just type", and will quickly converge to the
/// final per-minute total once the rollup catches up. That matches how
/// `todaySummary` treats its per-second layer.
public extension EventStore {

    /// Peak one-minute key-press count within `[start, capUntil)` along
    /// with the minute boundary it occurred in. Returns `nil` when the
    /// day has no key-press data at all (not even a single raw row).
    ///
    /// `capUntil` clamps the window so tests can freeze "now" without
    /// relying on wall-clock — identical convention as `todaySummary`.
    func peakKeyPressMinute(
        start: Date,
        capUntil: Date
    ) throws -> KeyPressPeakMinute? {
        let startSec = Int64(start.timeIntervalSince1970)
        let capSec = Int64(capUntil.timeIntervalSince1970)
        guard capSec > startSec else { return nil }

        return try database.queue.read { db -> KeyPressPeakMinute? in
            // L2 — `min_key.press_count` already holds the per-minute
            // total, so MAX() is enough.
            let minRow = try Row.fetchOne(db, sql: """
                SELECT ts_minute, press_count
                FROM min_key
                WHERE ts_minute >= ? AND ts_minute < ?
                ORDER BY press_count DESC, ts_minute ASC
                LIMIT 1
                """, arguments: [startSec, capSec])

            // L1 — sec_key is per-second; fold to minute and take the max.
            // `(ts_second / 60) * 60` yields the minute's floor timestamp
            // and lets us emit the same shape as the L2 query.
            let secRow = try Row.fetchOne(db, sql: """
                SELECT (ts_second / 60) * 60 AS ts_minute, SUM(press_count) AS press_count
                FROM sec_key
                WHERE ts_second >= ? AND ts_second < ?
                GROUP BY ts_minute
                ORDER BY press_count DESC, ts_minute ASC
                LIMIT 1
                """, arguments: [startSec, capSec])

            let minPeak: KeyPressPeakMinute? = minRow.map {
                KeyPressPeakMinute(
                    minuteStart: Date(timeIntervalSince1970: TimeInterval($0["ts_minute"] as Int64)),
                    pressCount: $0["press_count"] as Int
                )
            }
            let secPeak: KeyPressPeakMinute? = secRow.map {
                KeyPressPeakMinute(
                    minuteStart: Date(timeIntervalSince1970: TimeInterval($0["ts_minute"] as Int64)),
                    pressCount: $0["press_count"] as Int
                )
            }
            switch (minPeak, secPeak) {
            case let (.some(a), .some(b)):
                return a.pressCount >= b.pressCount ? a : b
            case let (.some(a), .none):
                return a
            case let (.none, .some(b)):
                return b
            case (.none, .none):
                return nil
            }
        }
    }
}

/// One minute's worth of key presses plus the minute boundary it covers.
/// F-12 uses it as "today's peak KPM at HH:mm" on the Dashboard.
public struct KeyPressPeakMinute: Sendable, Equatable {
    public let minuteStart: Date
    public let pressCount: Int

    public init(minuteStart: Date, pressCount: Int) {
        self.minuteStart = minuteStart
        self.pressCount = pressCount
    }

    /// Convenience alias — `press_count` for a one-minute bucket *is*
    /// KPM. Keeps call sites readable.
    public var kpm: Int { pressCount }
}

import Foundation
import GRDB

/// F-32 — read-side queries over the clipboard-change signal. The
/// collector emits `clipboard_change` rows into `system_events` every
/// time `NSPasteboard.general.changeCount` increments. Read queries
/// here count those rows per day / per hour-of-day for the dashboard
/// card.
public extension EventStore {

    /// Count of clipboard-change events on the local calendar day
    /// containing `day`, capped at `capUntil` so "today" doesn't
    /// include future events (which there shouldn't be, but cheap
    /// to guard).
    func dailyClipboardChanges(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Int {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endCap.timeIntervalSince1970 * 1_000)
        guard endMs > startMs else { return 0 }
        return try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM system_events
                WHERE category = 'clipboard_change' AND ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
        }
    }

    /// 24-element hour-of-day distribution of clipboard changes today
    /// (local time). Used by the card's mini sparkline so the user can
    /// see "I copy a lot in the morning" at a glance.
    func hourlyClipboardChanges(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [Int] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endCap.timeIntervalSince1970 * 1_000)
        let localOffset = Int64(calendar.timeZone.secondsFromGMT(for: dayStart))
        guard endMs > startMs else { return Array(repeating: 0, count: 24) }

        let rows: [(Int, Int)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                    CAST((((ts / 1000) + ?) / 3600) AS INTEGER) % 24 AS hour_of_day,
                    COUNT(*) AS hits
                FROM system_events
                WHERE category = 'clipboard_change'
                  AND ts >= ? AND ts < ?
                GROUP BY hour_of_day
                """, arguments: [localOffset, startMs, endMs])
                .map { row in
                    let h: Int = row["hour_of_day"]
                    let c: Int = row["hits"]
                    return (h, c)
                }
        }
        var hourly = Array(repeating: 0, count: 24)
        for (hour, count) in rows where (0..<24).contains(hour) {
            hourly[hour] = count
        }
        return hourly
    }
}

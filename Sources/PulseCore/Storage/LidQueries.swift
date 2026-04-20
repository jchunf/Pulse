import Foundation
import GRDB

/// F-27 — how many times the MacBook lid was opened in a given
/// window. `lid_opened` / `lid_closed` land in `system_events` from
/// the `LidPowerObserver` (IOKit `IOPMrootDomain` / `IOServicePM`).
/// We count opens rather than total toggles because each lid-open is
/// conceptually "the user came back to the Mac" — a concrete session
/// count, not a noisy +1 for every clamshell flip.
///
/// Desktop Macs never emit these events, so every query here
/// legitimately returns `0` for desktop users. The Dashboard uses
/// "any non-zero day in the history window" as the signal to show
/// the card at all (non-MacBook users get no empty-looking tile).
public extension EventStore {

    /// Count of `lid_opened` rows on the calendar day containing
    /// `day`, truncated at `capUntil` so "today" does not include
    /// future lid events (there shouldn't be any, but cheap to guard).
    func dailyLidOpens(
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
                WHERE category = 'lid_opened' AND ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
        }
    }

    /// Per-day lid-open counts over the `days` days ending at
    /// `endingAt` (inclusive), oldest → newest. Zero-pads every day
    /// in the window so the result is always `days` long — the
    /// Dashboard sparkline expects a dense series.
    func lidOpensTrend(
        endingAt: Date,
        days: Int = 7,
        calendar: Calendar = .current
    ) throws -> [Int] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else { return Array(repeating: 0, count: days) }
        let startMs = Int64(startDay.timeIntervalSince1970 * 1_000)
        let endMs = Int64(rangeEnd.timeIntervalSince1970 * 1_000)

        let timestampsMs = try database.queue.read { db -> [Int64] in
            try Int64.fetchAll(db, sql: """
                SELECT ts FROM system_events
                WHERE category = 'lid_opened' AND ts >= ? AND ts < ?
                """, arguments: [startMs, endMs])
        }

        var counts = Array(repeating: 0, count: days)
        for ms in timestampsMs {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            let dayStart = calendar.startOfDay(for: date)
            guard let idx = calendar.dateComponents([.day], from: startDay, to: dayStart).day,
                  idx >= 0, idx < days
            else { continue }
            counts[idx] += 1
        }
        return counts
    }
}

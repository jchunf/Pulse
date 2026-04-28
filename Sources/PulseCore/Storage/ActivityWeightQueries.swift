import Foundation
import GRDB

/// F-42 — daily active-hours curve over a multi-day window. The
/// "digital weight" metaphor: the user's attention has a daily total
/// like body weight has a daily measurement, and seeing the trend is
/// more useful than any single-day snapshot. Pure derivation from
/// `hour_summary` (uses `3600 − idle_seconds` as active seconds per
/// hour, then sums per local day).
///
/// Returns an array sorted ascending by day; days with no recorded
/// activity are returned with `activeHours == 0` rather than dropped,
/// so the consuming chart can show actual gaps in the timeline.
public extension EventStore {

    func activityWeight(
        endingAt: Date,
        days: Int = 30,
        calendar: Calendar = .current
    ) throws -> [ActivityWeightPoint] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            return []
        }
        let startSec = Int64(startDay.timeIntervalSince1970)
        let endSec = Int64(rangeEnd.timeIntervalSince1970)
        let localOffset = Int64(calendar.timeZone.secondsFromGMT(for: endingAt))

        // Fetch per-day active seconds. Uses the same local-midnight
        // bucketing as the rollup so a row recorded at wall-clock
        // 23:30 lands in the day the user perceives.
        let rows = try database.queue.read { db -> [(Int64, Int64)] in
            try Row.fetchAll(db, sql: """
                SELECT
                    (((ts_hour + ?) / 86400) * 86400) - ? AS day,
                    SUM(MAX(0, 3600 - MIN(3600, idle_seconds))) AS active_seconds
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                GROUP BY day
                """, arguments: [localOffset, localOffset, startSec, endSec])
                .map { row in
                    let d: Int64 = row["day"]
                    let s: Int64 = row["active_seconds"] ?? 0
                    return (d, s)
                }
        }

        // Pivot to a contiguous days-array: missing days return as
        // `activeHours = 0` so the chart can show actual gaps.
        let bySec: [Int64: Int64] = Dictionary(uniqueKeysWithValues: rows)
        var points: [ActivityWeightPoint] = []
        points.reserveCapacity(days)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let key = Int64(day.timeIntervalSince1970)
            let seconds = bySec[key] ?? 0
            points.append(
                ActivityWeightPoint(
                    day: day,
                    activeHours: Double(seconds) / 3600.0
                )
            )
        }
        return points
    }
}

/// One day's active-hours total for the F-42 curve. `activeHours` is
/// derived as `Σ (3600 − idle_seconds)` across the day's `hour_summary`
/// rows, divided by 3600.
public struct ActivityWeightPoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public let activeHours: Double

    public var id: Date { day }

    public init(day: Date, activeHours: Double) {
        self.day = day
        self.activeHours = activeHours
    }
}

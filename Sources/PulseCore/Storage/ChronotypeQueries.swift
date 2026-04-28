import Foundation
import GRDB

/// F-40 — derives the user's chronotype ("morning person / night owl /
/// split shift") from `hour_summary` over a multi-day window. Pure
/// derivation; no new collector or migration. The classification uses
/// the activity-weighted **circular mean hour** (handles the 23 → 0
/// wrap-around correctly) plus a 24-element hourly distribution that
/// the card can render as a sparkline so the user can verify the label
/// against the underlying shape.
public extension EventStore {

    /// Returns the user's chronotype across the last `days` days
    /// ending at `endingAt`, in local time. Returns `nil` when there
    /// isn't enough recorded activity to classify (e.g. fresh
    /// install — fewer than `minActiveSecondsForClassification`
    /// seconds across the whole window).
    func chronotype(
        endingAt: Date,
        days: Int = 14,
        minActiveSecondsForClassification: Int = 3 * 3600,
        calendar: Calendar = .current
    ) throws -> Chronotype? {
        precondition(days >= 1, "days must be at least 1")
        let endHour = calendar.startOfDay(for: endingAt).timeIntervalSince1970
        guard let startHour = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: endingAt))?.timeIntervalSince1970 else {
            return nil
        }
        let startSec = Int64(startHour)
        // `endingAt + 1h` so the hour containing `now` is included.
        let endSec = Int64(endingAt.timeIntervalSince1970) + 3600
        let localOffset = Int64(calendar.timeZone.secondsFromGMT(for: endingAt))

        // For each hour-of-day in local time, sum (60 * 60 - idle).
        // Idle seconds are clamped at 3600 server-side so the
        // subtraction below can't go negative even on degenerate
        // rows.
        let rows = try database.queue.read { db -> [(Int, Int64)] in
            try Row.fetchAll(db, sql: """
                SELECT
                    CAST(((ts_hour + ?) / 3600) AS INTEGER) % 24 AS hour_of_day,
                    SUM(MAX(0, 3600 - MIN(3600, idle_seconds))) AS active_seconds
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                GROUP BY hour_of_day
                """, arguments: [localOffset, startSec, endSec])
                .map { row in
                    let h: Int = row["hour_of_day"]
                    let s: Int64 = row["active_seconds"] ?? 0
                    return (h, s)
                }
        }

        // Pivot into a 24-element vector.
        var hourly = [Int](repeating: 0, count: 24)
        for (h, s) in rows where (0..<24).contains(h) {
            hourly[h] = Int(clamping: s)
        }
        let total = hourly.reduce(0, +)
        guard total >= minActiveSecondsForClassification else { return nil }

        // Activity-weighted circular mean. Each hour h contributes a
        // unit vector at angle (h / 24) * 2π weighted by its active
        // seconds; the mean direction's angle reads as the
        // "centre-of-mass hour" without the 23→0 boundary problem
        // a linear mean would have.
        var sumCos = 0.0
        var sumSin = 0.0
        for h in 0..<24 {
            let theta = (Double(h) / 24.0) * 2 * .pi
            let weight = Double(hourly[h])
            sumCos += weight * cos(theta)
            sumSin += weight * sin(theta)
        }
        var meanAngle = atan2(sumSin, sumCos)
        if meanAngle < 0 { meanAngle += 2 * .pi }
        let centerHour = meanAngle * (24.0 / (2 * .pi))

        // Peak hour as a tie-breaker / second display number.
        var peakHour = 0
        var peakValue = -1
        for h in 0..<24 where hourly[h] > peakValue {
            peakValue = hourly[h]
            peakHour = h
        }

        return Chronotype(
            label: ChronotypeLabel.classify(centerHour: centerHour),
            centerHour: centerHour,
            peakHour: peakHour,
            hourlyActiveSeconds: hourly,
            windowDays: days
        )
    }
}

/// Five-bucket chronotype classification keyed on the activity-
/// weighted circular-mean hour. Buckets are loosely informed by sleep-
/// research conventions but kept coarse enough that small day-to-day
/// shifts in working hours don't bounce the user between labels.
public enum ChronotypeLabel: String, Sendable, Hashable, Codable {
    case lateNight   // centre hour ∈ [0, 5)   — coding past midnight
    case earlyBird   // centre hour ∈ [5, 9)   — pre-9am peak
    case morning     // centre hour ∈ [9, 13)  — classic 9-to-noon worker
    case afternoon   // centre hour ∈ [13, 18) — standard office cadence
    case evening     // centre hour ∈ [18, 24) — post-dinner / night owl

    static func classify(centerHour h: Double) -> ChronotypeLabel {
        switch h {
        case ..<5:   return .lateNight
        case ..<9:   return .earlyBird
        case ..<13:  return .morning
        case ..<18:  return .afternoon
        default:     return .evening
        }
    }
}

/// Result of the chronotype derivation. `hourlyActiveSeconds` is a
/// 24-element vector so the card can render the underlying shape.
public struct Chronotype: Sendable, Equatable {
    public let label: ChronotypeLabel
    /// Activity-weighted circular-mean hour ∈ [0, 24).
    public let centerHour: Double
    /// Hour with the most active seconds across the window. Used as
    /// the headline number on the card ("most active around H:00").
    public let peakHour: Int
    /// Per-hour active seconds across all days in the window.
    /// `hourlyActiveSeconds[h]` is the sum across days of
    /// `(3600 - idle_seconds)` for hour `h` in local time.
    public let hourlyActiveSeconds: [Int]
    /// How many days the aggregation drew from. Surfaced in the card
    /// so the user can read the label as "based on N days".
    public let windowDays: Int

    public init(
        label: ChronotypeLabel,
        centerHour: Double,
        peakHour: Int,
        hourlyActiveSeconds: [Int],
        windowDays: Int
    ) {
        self.label = label
        self.centerHour = centerHour
        self.peakHour = peakHour
        self.hourlyActiveSeconds = hourlyActiveSeconds
        self.windowDays = windowDays
    }
}

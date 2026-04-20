import Foundation
import GRDB

/// F-11 — "don't break the streak" continuity grid. GitHub's
/// contribution graph, scoped to Pulse's `hour_summary` layer. The
/// query is intentionally tiny: one pass over `hour_summary` within
/// the window, bucketed by local day, producing per-day active-hour
/// counts + derived streak statistics.
///
/// `hour_summary` is the L3 rollup — rows land only after the hour
/// closes. The current in-progress hour therefore does **not**
/// contribute. This mirrors `hourlyHeatmap` / `dailyTrend` staleness:
/// acceptable for a long-window pattern visualisation.
public extension EventStore {

    /// Per-day activity recap + streak statistics over the `days` days
    /// ending at `endingAt` (inclusive).
    ///
    /// A day **qualifies** toward the streak when at least
    /// `activeHoursThreshold` distinct hours of that local day recorded
    /// non-zero activity (`key_press_total + mouse_click_total +
    /// scroll_ticks > 0`) in `hour_summary`. 4 hours is the spec
    /// baseline from `docs/02-features.md#F-11`.
    ///
    /// - `currentStreak`: consecutive qualifying days ending **at the
    ///   latest day in the window**. Zero when the latest day does not
    ///   qualify — streak broken. Callers that want to show "today is
    ///   still in progress" can separately inspect
    ///   `days.last?.qualified` and `days.last?.activeHours`.
    /// - `longestStreak`: largest consecutive qualifying run anywhere
    ///   in the window.
    /// - `qualifyingDays`: total qualifying days in the window.
    func continuityStreak(
        endingAt: Date,
        days: Int = 365,
        activeHoursThreshold: Int = 4,
        calendar: Calendar = .current
    ) throws -> ContinuityStreak {
        precondition(days >= 1, "days must be at least 1")
        precondition(activeHoursThreshold >= 1, "activeHoursThreshold must be at least 1")

        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            return ContinuityStreak(days: [], currentStreak: 0, longestStreak: 0, qualifyingDays: 0, windowDays: 0)
        }
        let rangeStartSec = Int64(startDay.timeIntervalSince1970)
        let rangeEndSec = Int64(rangeEnd.timeIntervalSince1970)

        // One row per hour that had any user-initiated event. `ts_hour`
        // is the UTC second of the hour's start; day bucketing happens
        // below with the caller's calendar (usually .current) so DST
        // and timezone shifts land on the right local day.
        let tsHours = try database.queue.read { db -> [Int64] in
            try Int64.fetchAll(db, sql: """
                SELECT ts_hour FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                  AND (key_press_total + mouse_click_total + scroll_ticks) > 0
                """, arguments: [rangeStartSec, rangeEndSec])
        }

        // Index: dayOffsetFromStart -> count of active hours that day.
        // `ts_hour` is a primary key so each row already represents a
        // unique hour; a simple counter is enough.
        var activeHoursByDayIndex: [Int: Int] = [:]
        for ts in tsHours {
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let dayStart = calendar.startOfDay(for: date)
            guard let dayIndex = calendar.dateComponents([.day], from: startDay, to: dayStart).day,
                  dayIndex >= 0, dayIndex < days
            else {
                continue
            }
            activeHoursByDayIndex[dayIndex, default: 0] += 1
        }

        var continuityDays: [ContinuityDay] = []
        continuityDays.reserveCapacity(days)
        var qualifyingCount = 0
        for index in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: index, to: startDay) else { continue }
            let activeHours = activeHoursByDayIndex[index] ?? 0
            let qualified = activeHours >= activeHoursThreshold
            if qualified { qualifyingCount += 1 }
            continuityDays.append(ContinuityDay(day: day, activeHours: activeHours, qualified: qualified))
        }

        let (currentStreak, longestStreak) = Self.streakStatistics(continuityDays.map(\.qualified))

        return ContinuityStreak(
            days: continuityDays,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            qualifyingDays: qualifyingCount,
            windowDays: days
        )
    }

    /// `current` is the run of consecutive `true`s anchored at the
    /// **last** index — 0 when the last element is `false`. `longest`
    /// is the largest run anywhere in the array. Factored out so
    /// tests + UI can reuse the same rule without a database.
    internal static func streakStatistics(_ qualified: [Bool]) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        for isQualified in qualified {
            if isQualified {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        // `run` is already 0 when the last element was false, so it is
        // exactly the trailing streak.
        return (run, longest)
    }
}

// MARK: - Value types

/// One calendar day in the continuity grid. `activeHours` is 0–24;
/// `qualified` is derived from the caller's threshold.
public struct ContinuityDay: Sendable, Equatable {
    public let day: Date
    public let activeHours: Int
    public let qualified: Bool

    public init(day: Date, activeHours: Int, qualified: Bool) {
        self.day = day
        self.activeHours = activeHours
        self.qualified = qualified
    }
}

/// Window-level recap of the continuity grid: per-day cells plus
/// streak statistics derived from `days.map(\.qualified)`.
public struct ContinuityStreak: Sendable, Equatable {
    public let days: [ContinuityDay]
    public let currentStreak: Int
    public let longestStreak: Int
    public let qualifyingDays: Int
    public let windowDays: Int

    public init(
        days: [ContinuityDay],
        currentStreak: Int,
        longestStreak: Int,
        qualifyingDays: Int,
        windowDays: Int
    ) {
        self.days = days
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.qualifyingDays = qualifyingDays
        self.windowDays = windowDays
    }
}

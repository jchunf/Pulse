import Foundation

/// The three rules that ship in the first A27 slice. The review
/// (§3.4) calls for "transparent, auditable, rule-based" — each
/// rule's thresholds live in a single `public let` constant so a
/// skim of this file is enough to know exactly when each insight
/// fires. Change a threshold → same rule's tests immediately
/// describe the new boundary; add a rule → append a case to
/// `InsightPayload` + a String Catalog entry + a test.
public enum DefaultInsightRules {
    /// Registration order drives UI order. Hourly comes first because
    /// "your 14:00 was 60% quieter" is more actionable than the
    /// day-level activity-anomaly signal the summary cards'
    /// delta-vs-yesterday already conveys.
    public static let all: [any InsightRule] = [
        HourlyActivityAnomalyRule(),
        DeepFocusStandoutRule(),
        SingleAppDominanceRule(),
        ActivityAnomalyRule()
    ]
}

// MARK: - Activity anomaly

/// Fires when today's key-press count diverges from the median of
/// the prior days in the window by ≥ `thresholdPercent`. Minimum
/// history guard keeps the rule quiet during the first week of use
/// when the baseline is too noisy to trust. Median (not mean) so
/// one wild day doesn't move the reference point.
public struct ActivityAnomalyRule: InsightRule {

    public let id = "activity_anomaly"
    public let thresholdPercent: Double
    public let minimumHistoryDays: Int
    public let medianFloor: Int

    /// Defaults match the review's ±30% mention and a three-day
    /// history floor that lines up with the heatmap's 3-day mode.
    public init(
        thresholdPercent: Double = 30.0,
        minimumHistoryDays: Int = 3,
        medianFloor: Int = 100
    ) {
        self.thresholdPercent = thresholdPercent
        self.minimumHistoryDays = minimumHistoryDays
        self.medianFloor = medianFloor
    }

    public func evaluate(context: InsightContext) -> Insight? {
        let history = context.pastDailyTrend
            .map(\.keyPresses)
            .filter { $0 > 0 }
        guard history.count >= minimumHistoryDays,
              let median = InsightStatistics.median(history),
              median >= medianFloor
        else {
            return nil
        }

        let today = context.today.totalKeyPresses
        // A day with zero activity is almost always "Pulse wasn't
        // running" — flagging it as "100% below normal" is
        // technically true but useless, so we skip it entirely.
        guard today > 0 else { return nil }

        let deltaPercent = (Double(today) - Double(median)) / Double(median) * 100.0
        guard abs(deltaPercent) >= thresholdPercent else { return nil }

        return Insight(
            id: id,
            kind: .curious,
            payload: .activityAnomaly(
                direction: deltaPercent > 0 ? .above : .below,
                percentOff: Int(abs(deltaPercent).rounded()),
                todayKeys: today,
                medianKeys: median
            )
        )
    }
}

// MARK: - Deep-focus standout

/// Fires when today's longest focus segment beats the median of
/// prior-day longest segments by ≥ `standoutMultiplier` (default
/// 1.3×). Designed to celebrate a notably productive run without
/// nagging about bad days — only the positive direction is
/// surfaced. Requires a minimum absolute duration so two 5-minute
/// segments (one "30% longer" than another) don't generate an
/// insight about a session that would barely count as focus.
public struct DeepFocusStandoutRule: InsightRule {

    public let id = "deep_focus_standout"
    public let standoutMultiplier: Double
    public let minimumTodaySeconds: Int
    public let minimumHistoryDays: Int

    public init(
        standoutMultiplier: Double = 1.3,
        minimumTodaySeconds: Int = 25 * 60,
        minimumHistoryDays: Int = 3
    ) {
        self.standoutMultiplier = standoutMultiplier
        self.minimumTodaySeconds = minimumTodaySeconds
        self.minimumHistoryDays = minimumHistoryDays
    }

    public func evaluate(context: InsightContext) -> Insight? {
        guard let today = context.todayLongestFocus,
              today.durationSeconds >= minimumTodaySeconds
        else {
            return nil
        }

        let history = context.pastLongestFocusSeconds.filter { $0 > 0 }
        guard history.count >= minimumHistoryDays,
              let median = InsightStatistics.median(history),
              median > 0
        else {
            return nil
        }

        let ratio = Double(today.durationSeconds) / Double(median)
        guard ratio >= standoutMultiplier else { return nil }

        let percentAbove = Int(((ratio - 1.0) * 100.0).rounded())
        return Insight(
            id: id,
            kind: .celebratory,
            payload: .deepFocusStandout(
                todayLongestSeconds: today.durationSeconds,
                medianLongestSeconds: median,
                bundleId: today.bundleId,
                percentAbove: percentAbove
            )
        )
    }
}

// MARK: - Hourly activity anomaly

/// Fires on the **single completed** hour of today with the largest
/// magnitude deviation from the median of that same hour-of-day in
/// the prior days of the heatmap window. Skipped entirely when:
///
/// - history for that hour has fewer than `minimumHistoryDays`
///   non-zero observations,
/// - the same-hour median is below `medianFloor` (a typo-size
///   baseline doesn't justify "900% above" dramatics),
/// - today's hour has no cell in the heatmap *and* the direction
///   would be "below" — the `hourlyHeatmap` query omits zero-activity
///   rows, so a missing today cell is indistinguishable from "Pulse
///   wasn't running then"; the rule chooses to stay silent rather
///   than risk a false positive. (A missing today cell in the
///   "above" direction is impossible by definition — "above" needs
///   today's count to exceed the median.)
///
/// Emits at most one insight per evaluation — picking the hour with
/// the highest `|percentOff|` — so the card stays a glance rather
/// than a list of every outlier hour.
public struct HourlyActivityAnomalyRule: InsightRule {

    public let id = "hourly_activity_anomaly"
    public let thresholdPercent: Double
    public let minimumHistoryDays: Int
    public let medianFloor: Int

    /// 50% is deliberately stricter than the day-level rule's 30% —
    /// single hours are noisier than full-day aggregates, so we
    /// want a louder signal before flagging "your 14:00 was weird".
    public init(
        thresholdPercent: Double = 50.0,
        minimumHistoryDays: Int = 3,
        medianFloor: Int = 30
    ) {
        self.thresholdPercent = thresholdPercent
        self.minimumHistoryDays = minimumHistoryDays
        self.medianFloor = medianFloor
    }

    public func evaluate(context: InsightContext) -> Insight? {
        let currentHour = context.calendar.component(.hour, from: context.now)
        guard currentHour > 0 else { return nil } // Midnight: no completed hours yet.

        // Pre-index today / past cells by hour for O(24) scan.
        var todayByHour: [Int: Int] = [:]
        var pastByHour: [Int: [Int]] = [:]
        for cell in context.heatmapCells {
            if cell.dayOffset == 0 {
                todayByHour[cell.hour] = cell.activityCount
            } else if cell.dayOffset > 0 {
                pastByHour[cell.hour, default: []].append(cell.activityCount)
            }
        }

        var best: (
            hour: Int,
            direction: InsightPayload.Direction,
            percentOff: Int,
            today: Int,
            median: Int,
            magnitude: Double
        )? = nil

        for hour in 0..<currentHour {
            let history = (pastByHour[hour] ?? []).filter { $0 > 0 }
            guard history.count >= minimumHistoryDays,
                  let median = InsightStatistics.median(history),
                  median >= medianFloor
            else {
                continue
            }

            let today = todayByHour[hour] ?? 0
            // Missing today cell in "below" direction is ambiguous —
            // Pulse off vs. legitimately quiet. See docstring.
            if today == 0 { continue }

            let deltaPercent = (Double(today) - Double(median)) / Double(median) * 100.0
            let magnitude = abs(deltaPercent)
            guard magnitude >= thresholdPercent else { continue }

            if best == nil || magnitude > (best?.magnitude ?? 0) {
                best = (
                    hour: hour,
                    direction: deltaPercent > 0 ? .above : .below,
                    percentOff: Int(magnitude.rounded()),
                    today: today,
                    median: median,
                    magnitude: magnitude
                )
            }
        }

        guard let pick = best else { return nil }
        return Insight(
            id: id,
            kind: .curious,
            payload: .hourlyActivityAnomaly(
                hour: pick.hour,
                direction: pick.direction,
                percentOff: pick.percentOff,
                todayCount: pick.today,
                medianCount: pick.median
            )
        )
    }
}

// MARK: - Single-app dominance

/// Fires when one app accounts for more than `dominanceFraction` of
/// today's active time. Deliberately neutral in tone — the review
/// (§3.6) frames this as self-awareness ("are you a mono-app user
/// today?") rather than judgement.
public struct SingleAppDominanceRule: InsightRule {

    public let id = "single_app_dominance"
    public let dominanceFraction: Double
    public let minimumActiveSeconds: Int

    public init(
        dominanceFraction: Double = 0.5,
        minimumActiveSeconds: Int = 30 * 60
    ) {
        self.dominanceFraction = dominanceFraction
        self.minimumActiveSeconds = minimumActiveSeconds
    }

    public func evaluate(context: InsightContext) -> Insight? {
        let totalActive = context.today.totalActiveSeconds
        guard totalActive >= minimumActiveSeconds,
              let top = context.today.topApps.first,
              top.secondsUsed > 0
        else {
            return nil
        }

        let fraction = Double(top.secondsUsed) / Double(totalActive)
        guard fraction >= dominanceFraction else { return nil }

        return Insight(
            id: id,
            kind: .curious,
            payload: .singleAppDominance(
                bundleId: top.bundleId,
                fractionOfActive: fraction,
                secondsInApp: top.secondsUsed
            )
        )
    }
}

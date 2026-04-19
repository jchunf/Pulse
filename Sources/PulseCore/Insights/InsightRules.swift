import Foundation

/// The three rules that ship in the first A27 slice. The review
/// (§3.4) calls for "transparent, auditable, rule-based" — each
/// rule's thresholds live in a single `public let` constant so a
/// skim of this file is enough to know exactly when each insight
/// fires. Change a threshold → same rule's tests immediately
/// describe the new boundary; add a rule → append a case to
/// `InsightPayload` + a String Catalog entry + a test.
public enum DefaultInsightRules {
    public static let all: [any InsightRule] = [
        ActivityAnomalyRule(),
        DeepFocusStandoutRule(),
        SingleAppDominanceRule()
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

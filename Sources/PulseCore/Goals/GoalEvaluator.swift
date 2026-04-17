import Foundation

/// Pure function that evaluates a set of goals against today's live
/// measurements. PulseCore doesn't store the enabled-goal set — that
/// lives in `UserDefaults` in the app layer — but it does compute the
/// progress line-by-line so every consumer renders the same numbers.
public enum GoalEvaluator {

    /// Evaluate every supplied goal. Non-configured metrics (i.e.
    /// `appSwitchesToday` nil when someone asks for the switches goal)
    /// produce a `GoalProgress` with `actualValue = 0`.
    public static func evaluate(
        goals: [GoalDefinition],
        summary: TodaySummary,
        longestFocus: FocusSegment?,
        appSwitchesToday: Int?
    ) -> [GoalProgress] {
        goals.map { goal in
            let actual = actualValue(
                for: goal.metric,
                summary: summary,
                longestFocus: longestFocus,
                appSwitchesToday: appSwitchesToday
            )
            let achieved: Bool
            switch goal.direction {
            case .atLeast: achieved = actual >= goal.target
            case .atMost:  achieved = actual <= goal.target
            }
            let fraction: Double = {
                guard goal.target > 0 else { return achieved ? 1 : 0 }
                switch goal.direction {
                case .atLeast:
                    return min(1, max(0, actual / goal.target))
                case .atMost:
                    // For "at most" goals, 0 usage is "full progress"
                    // toward the goal; exceeding target drops the bar
                    // to empty. Visually: full green bar = you're under
                    // the ceiling, empty bar = over.
                    let ratio = actual / goal.target
                    return min(1, max(0, 1 - (ratio - 1)))
                }
            }()
            return GoalProgress(
                definition: goal,
                actualValue: actual,
                isAchieved: achieved,
                fractionTowardsTarget: fraction
            )
        }
    }

    private static func actualValue(
        for metric: GoalMetric,
        summary: TodaySummary,
        longestFocus: FocusSegment?,
        appSwitchesToday: Int?
    ) -> Double {
        switch metric {
        case .activeSeconds:
            return Double(summary.totalActiveSeconds)
        case .longestFocusSeconds:
            return Double(longestFocus?.durationSeconds ?? 0)
        case .appSwitches:
            return Double(appSwitchesToday ?? 0)
        case .keystrokes:
            return Double(summary.totalKeyPresses)
        }
    }
}

import Foundation

/// Metric a goal references. Keeps PulseCore free of any UI vocabulary;
/// localized labels are supplied by the app layer.
public enum GoalMetric: String, Codable, Sendable, Equatable, CaseIterable {
    /// Total seconds a user-owned app was foreground today.
    case activeSeconds
    /// Duration of today's single longest uninterrupted focus run.
    case longestFocusSeconds
    /// Count of `foreground_app` transitions today.
    case appSwitches
    /// Total keystrokes today.
    case keystrokes
}

public enum GoalDirection: String, Codable, Sendable, Equatable {
    case atLeast
    case atMost
}

/// A single line of intent — "I want to focus for ≥ 3h today" or "I want
/// fewer than 30 app switches". Identifiable by a stable key so presets
/// can round-trip through `UserDefaults` without UUID churn.
public struct GoalDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let metric: GoalMetric
    public let direction: GoalDirection
    public let target: Double

    public init(id: String, metric: GoalMetric, direction: GoalDirection, target: Double) {
        self.id = id
        self.metric = metric
        self.direction = direction
        self.target = target
    }
}

/// Evaluation output for a single goal at a point in time.
public struct GoalProgress: Sendable, Equatable, Identifiable {
    public let definition: GoalDefinition
    public let actualValue: Double
    public let isAchieved: Bool
    /// `actualValue / target` clamped to `[0, 1]`. Intended as the
    /// visible progress-bar fill — caps at 1.0 so overshoots don't
    /// overflow the layout.
    public let fractionTowardsTarget: Double

    public var id: String { definition.id }

    public init(
        definition: GoalDefinition,
        actualValue: Double,
        isAchieved: Bool,
        fractionTowardsTarget: Double
    ) {
        self.definition = definition
        self.actualValue = actualValue
        self.isAchieved = isAchieved
        self.fractionTowardsTarget = fractionTowardsTarget
    }
}

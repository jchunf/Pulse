import Foundation

/// A single rule the engine runs once per refresh. Rules are pure
/// over `InsightContext` — no I/O, no clock access, no database
/// reads — so they stay trivially unit-testable with fake contexts.
///
/// The engine never filters or reorders rule output; ordering comes
/// from the registered rule array. UI should cap how many insights
/// it shows (2-3 is plenty; Dashboard clutter is the failure mode).
public protocol InsightRule: Sendable {
    /// Stable identifier used as the `Insight.id`. Must not collide
    /// across rules — dedup at the engine layer relies on it and so
    /// does any future "dismiss this insight" persistence.
    var id: String { get }

    /// Evaluate the rule against today's snapshot. Return `nil` when
    /// the rule's threshold is not met — the engine drops `nil`s so
    /// rules don't need to emit placeholder values.
    func evaluate(context: InsightContext) -> Insight?
}

/// Everything a rule might need to inspect, assembled once per
/// Dashboard refresh by the caller that has database access.
/// `pastDailyTrend` excludes today (the last slot in the queried
/// window). `pastLongestFocusSeconds` is one integer per prior day
/// in the window, same exclusion. `heatmapCells` is the raw output
/// of `EventStore.hourlyHeatmap(endingAt:days:)` so hourly rules
/// can carve it up per their own needs. Anything derivable from
/// these fields should stay inside the rule; anything requiring a
/// fresh DB query should land as a new field here so rules stay pure.
public struct InsightContext: Sendable {

    public let today: TodaySummary
    public let pastDailyTrend: [DailyTrendPoint]
    public let todayLongestFocus: FocusSegment?
    public let pastLongestFocusSeconds: [Int]
    public let heatmapCells: [HeatmapCell]
    public let now: Date
    public let calendar: Calendar

    public init(
        today: TodaySummary,
        pastDailyTrend: [DailyTrendPoint],
        todayLongestFocus: FocusSegment?,
        pastLongestFocusSeconds: [Int],
        heatmapCells: [HeatmapCell] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.today = today
        self.pastDailyTrend = pastDailyTrend
        self.todayLongestFocus = todayLongestFocus
        self.pastLongestFocusSeconds = pastLongestFocusSeconds
        self.heatmapCells = heatmapCells
        self.now = now
        self.calendar = calendar
    }
}

/// Median helper shared by the default rules. Public so a custom
/// rule in a downstream test can compute the same baseline without
/// pulling in a stats dependency. Returns `nil` on an empty array
/// so callers don't have to special-case missing history.
public enum InsightStatistics {
    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}

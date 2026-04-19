import Foundation

/// Runs the registered rules against a snapshot and returns the
/// insights that fired, in registration order. Pure: no I/O, no
/// clock, no locale — the database fetching is the caller's job
/// (see `DashboardModel.refresh()`), the string rendering is the
/// UI's job (see `InsightsCard`).
///
/// Keep this trivially small. Resist the urge to add sorting,
/// scoring, deduping, or rate limiting here — those belong in a
/// future layer once we have data on which rules actually fire.
public struct InsightEngine: Sendable {

    public let rules: [any InsightRule]

    public init(rules: [any InsightRule] = DefaultInsightRules.all) {
        self.rules = rules
    }

    public func evaluate(context: InsightContext) -> [Insight] {
        rules.compactMap { $0.evaluate(context: context) }
    }
}

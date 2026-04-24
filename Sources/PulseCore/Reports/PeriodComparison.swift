import Foundation

/// One metric's week-over-week (or month-over-month) movement.
/// `previousValue == 0` means the comparison is undefined — the card
/// renders "new" instead of a %Δ chip. Kept as a plain value type so
/// the app layer can pass it straight to a View without touching the
/// store.
public struct PeriodComparisonRow: Sendable, Equatable {
    public let metric: PeriodMetric
    public let currentValue: Double
    public let previousValue: Double

    public init(metric: PeriodMetric, currentValue: Double, previousValue: Double) {
        self.metric = metric
        self.currentValue = currentValue
        self.previousValue = previousValue
    }

    /// `(current − previous) / previous`, or `nil` when the previous
    /// bucket was empty. Clamps at `nil` rather than `.infinity` so the
    /// UI never has to format infinities.
    public var deltaFraction: Double? {
        guard previousValue > 0 else { return nil }
        return (currentValue - previousValue) / previousValue
    }
}

/// The metric dimension a `PeriodComparisonRow` reports on. The values
/// come directly from `DailyTrendPoint` so F-43 doesn't need a new
/// query — the 14-day trend query already running for the weekly chart
/// provides the raw inputs.
public enum PeriodMetric: String, Sendable, Equatable, CaseIterable {
    case keystrokes
    case mouseClicks
    case mouseDistanceMillimeters
    case scrollTicks
}

/// A pairing of "this week" vs "last week" totals across the four
/// dimensions. Backs the F-43 card on the Dashboard's Rhythm section.
public struct PeriodComparison: Sendable, Equatable {
    public let rows: [PeriodComparisonRow]
    public let currentPeriodDayCount: Int
    public let previousPeriodDayCount: Int

    public init(
        rows: [PeriodComparisonRow],
        currentPeriodDayCount: Int,
        previousPeriodDayCount: Int
    ) {
        self.rows = rows
        self.currentPeriodDayCount = currentPeriodDayCount
        self.previousPeriodDayCount = previousPeriodDayCount
    }

    public subscript(metric: PeriodMetric) -> PeriodComparisonRow? {
        rows.first { $0.metric == metric }
    }
}

/// Builds a `PeriodComparison` from a trend series. Pure — no I/O, so
/// the app layer can call it synchronously and tests can exercise the
/// edge cases directly.
///
/// F-43 splits the series into two equal halves: the oldest half is
/// the "previous" period, the newest half is the "current" period.
/// That means 14 rows → 7 vs 7 (week-over-week), 60 rows → 30 vs 30
/// (month-over-month). Odd counts drop the oldest row so both halves
/// stay equal length — a week-over-week card that silently compares
/// 7 days against 8 would be misleading.
public enum PeriodComparisonBuilder {

    /// Returns a comparison over the newest half vs the older half.
    /// `trend` is oldest-first (same order `EventStore.dailyTrend`
    /// produces). Returns `nil` when `trend.count < 2` — a single
    /// day can't be compared against anything.
    public static func split(from trend: [DailyTrendPoint]) -> PeriodComparison? {
        guard trend.count >= 2 else { return nil }
        let evenCount = (trend.count / 2) * 2
        let half = evenCount / 2
        let tail = Array(trend.suffix(evenCount))
        let previous = Array(tail.prefix(half))
        let current = Array(tail.suffix(half))

        let rows: [PeriodComparisonRow] = PeriodMetric.allCases.map { metric in
            PeriodComparisonRow(
                metric: metric,
                currentValue: sum(current, metric: metric),
                previousValue: sum(previous, metric: metric)
            )
        }
        return PeriodComparison(
            rows: rows,
            currentPeriodDayCount: current.count,
            previousPeriodDayCount: previous.count
        )
    }

    private static func sum(_ points: [DailyTrendPoint], metric: PeriodMetric) -> Double {
        switch metric {
        case .keystrokes:
            return points.reduce(0) { $0 + Double($1.keyPresses) }
        case .mouseClicks:
            return points.reduce(0) { $0 + Double($1.mouseClicks) }
        case .mouseDistanceMillimeters:
            return points.reduce(0) { $0 + $1.mouseDistanceMillimeters }
        case .scrollTicks:
            return points.reduce(0) { $0 + Double($1.scrollTicks) }
        }
    }
}

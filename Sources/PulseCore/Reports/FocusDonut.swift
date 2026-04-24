import Foundation

/// F-09 — per-category time breakdown for today's focus donut.
/// Built by summing `appUsageRanking` rows through
/// `AppCategoryClassifier`. Kept as a value type so the app layer
/// can hand it to the donut renderer straight out of
/// `DashboardModel`.
public struct FocusDonut: Sendable, Equatable {
    public let segments: [FocusDonutSegment]

    public init(segments: [FocusDonutSegment]) {
        self.segments = segments
    }

    public static let empty = FocusDonut(segments: [])

    public var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.seconds }
    }

    /// Fraction of the day's active time spent in the `.deepFocus`
    /// segment. The Dashboard surfaces this as the headline %.
    /// Returns 0 when the day has no tracked activity yet.
    public var deepFocusFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        let deep = segments.first { $0.category == .deepFocus }?.seconds ?? 0
        return Double(deep) / Double(totalSeconds)
    }
}

public struct FocusDonutSegment: Sendable, Equatable, Identifiable {
    public let category: AppCategory
    public let seconds: Int

    public var id: AppCategory { category }

    public init(category: AppCategory, seconds: Int) {
        self.category = category
        self.seconds = seconds
    }
}

public enum FocusDonutBuilder {

    /// Fold per-bundle foreground seconds into four `AppCategory`
    /// segments. Input `rows` is the output of `appUsageRanking` (or
    /// the `topApps` field on `TodaySummary`). Output preserves
    /// canonical segment order — `.deepFocus → .communication →
    /// .browsing → .other` — so the donut renders stable slice
    /// positions day over day. Zero-second segments are kept so the
    /// legend always shows all four buckets.
    public static func build(from rows: [AppUsageRow]) -> FocusDonut {
        var totals: [AppCategory: Int] = [:]
        for row in rows {
            let category = AppCategoryClassifier.category(for: row.bundleId)
            totals[category, default: 0] += row.secondsUsed
        }
        let segments: [FocusDonutSegment] = AppCategory.allCases.map { category in
            FocusDonutSegment(category: category, seconds: totals[category] ?? 0)
        }
        return FocusDonut(segments: segments)
    }
}

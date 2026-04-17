import Foundation

/// Dimension Pulse compares against a reference anchor. Distance keeps its
/// own `LandmarkLibrary` because the hero card wants the full 8-tier
/// dramatic ladder; `NarrativeEngine` fills the other axes the review
/// (`reviews/2026-04-17-product-direction.md#22`) asks to dramatize:
/// keystrokes and focus duration for now, more to follow.
public enum NarrativeMetric: String, Sendable, Equatable, CaseIterable {
    case keystrokes
    case focusDurationSeconds
}

/// A reference value a metric can be multiplied against to produce a
/// human-readable comparison. Mirrors `Landmark` from
/// `LandmarkComparison.swift` but generalized across metrics.
public struct NarrativeAnchor: Sendable, Equatable {
    public let key: String              // stable id, e.g. "focus.episode"
    public let displayName: String      // English default, used for logs
    public let valueInMetricUnits: Double
    public let metric: NarrativeMetric

    public init(
        key: String,
        displayName: String,
        valueInMetricUnits: Double,
        metric: NarrativeMetric
    ) {
        self.key = key
        self.displayName = displayName
        self.valueInMetricUnits = valueInMetricUnits
        self.metric = metric
    }
}

/// "Your typing today is ~3× a short story." Carries enough structured
/// data for the View layer to pick a localized sentence template.
public struct NarrativeComparison: Sendable, Equatable {
    public let anchor: NarrativeAnchor
    public let multiplier: Double
    public let metric: NarrativeMetric
    public let rawValue: Double

    public init(
        anchor: NarrativeAnchor,
        multiplier: Double,
        metric: NarrativeMetric,
        rawValue: Double
    ) {
        self.anchor = anchor
        self.multiplier = multiplier
        self.metric = metric
        self.rawValue = rawValue
    }
}

/// Generalisation of `LandmarkLibrary`'s "pick the most dramatic but still
/// sensible anchor" heuristic to any metric. See `reviews/` for the
/// product rationale: the review flags the Landmark pattern as Pulse's
/// most distinctive design move and asks to extend it to every
/// headline number.
///
/// Picks the largest anchor whose reference value is ≤ the input, so a
/// first-day number maps to a small anchor ("≈ 1 tweet's worth") and a
/// long-running number maps to an impressive one ("≈ 12× a feature film").
public struct NarrativeEngine: Sendable {

    public let anchors: [NarrativeMetric: [NarrativeAnchor]]

    public init(anchors: [NarrativeMetric: [NarrativeAnchor]]) {
        self.anchors = anchors.mapValues { list in
            list.sorted(by: { $0.valueInMetricUnits < $1.valueInMetricUnits })
        }
    }

    /// Default library shipped with Pulse. Values are deliberately
    /// evocative / round rather than research-grade precise.
    public static let standard = NarrativeEngine(anchors: [
        .keystrokes: [
            NarrativeAnchor(key: "keystrokes.headline", displayName: "news headline",
                            valueInMetricUnits: 80,
                            metric: .keystrokes),
            NarrativeAnchor(key: "keystrokes.sms", displayName: "text message",
                            valueInMetricUnits: 160,
                            metric: .keystrokes),
            NarrativeAnchor(key: "keystrokes.tweet", displayName: "tweet",
                            valueInMetricUnits: 280,
                            metric: .keystrokes),
            NarrativeAnchor(key: "keystrokes.shortStory", displayName: "short story",
                            valueInMetricUnits: 5_000,
                            metric: .keystrokes),
            NarrativeAnchor(key: "keystrokes.novella", displayName: "novella",
                            valueInMetricUnits: 40_000,
                            metric: .keystrokes),
            NarrativeAnchor(key: "keystrokes.novel", displayName: "novel",
                            valueInMetricUnits: 100_000,
                            metric: .keystrokes)
        ],
        .focusDurationSeconds: [
            NarrativeAnchor(key: "focus.pomodoro", displayName: "pomodoro",
                            valueInMetricUnits: 25 * 60,
                            metric: .focusDurationSeconds),
            NarrativeAnchor(key: "focus.episode", displayName: "episode of a sitcom",
                            valueInMetricUnits: 22 * 60,
                            metric: .focusDurationSeconds),
            NarrativeAnchor(key: "focus.shortFilm", displayName: "short film",
                            valueInMetricUnits: 15 * 60,
                            metric: .focusDurationSeconds),
            NarrativeAnchor(key: "focus.feature", displayName: "feature film",
                            valueInMetricUnits: 120 * 60,
                            metric: .focusDurationSeconds),
            NarrativeAnchor(key: "focus.workday", displayName: "full work day",
                            valueInMetricUnits: 8 * 60 * 60,
                            metric: .focusDurationSeconds)
        ]
    ])

    /// Pick the best anchor for the given metric + value, or `nil` when
    /// the value is too small to say anything interesting (below the
    /// smallest anchor's floor) or when the metric isn't configured.
    public func bestMatch(metric: NarrativeMetric, value: Double) -> NarrativeComparison? {
        guard value > 0,
              let candidates = anchors[metric],
              let first = candidates.first else {
            return nil
        }
        // Below the smallest anchor we deliberately return `nil`. For
        // distance we let the hero card carry the narrative; for other
        // metrics, a value below the floor (e.g. 12 keystrokes is less
        // than a headline) just doesn't need a dramatic line.
        guard value >= first.valueInMetricUnits else { return nil }
        let match = candidates.last(where: { $0.valueInMetricUnits <= value }) ?? first
        let multiplier = match.valueInMetricUnits > 0 ? value / match.valueInMetricUnits : 0
        return NarrativeComparison(
            anchor: match,
            multiplier: multiplier,
            metric: metric,
            rawValue: value
        )
    }
}

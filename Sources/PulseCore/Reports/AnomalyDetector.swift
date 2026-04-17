import Foundation

/// Pure decision function: given today's live summary and the past 7
/// days' trend points, is today an "anomaly" worth flagging on the menu
/// bar? The review (`reviews/2026-04-17-product-direction.md§2.1`)
/// suggests a ±30% deviation from the 7-day median as the cheapest
/// retention cue we can compute.
///
/// The detector is metric-agnostic: a single metric with a large enough
/// gap flips the badge on. Metrics that have zero history in `past`
/// are ignored, so a fresh install won't permanently glow red.
public enum AnomalyDetector {

    public static let defaultThreshold: Double = 0.30

    public static func hasAnomaly(
        today: TodaySummary,
        past: [DailyTrendPoint],
        threshold: Double = defaultThreshold,
        minimumSamples: Int = 3
    ) -> Bool {
        let pastKeys     = past.map { Double($0.keyPresses) }
        let pastClicks   = past.map { Double($0.mouseClicks) }
        let pastDistance = past.map { $0.mouseDistanceMillimeters }
        let pastScrolls  = past.map { Double($0.scrollTicks) }

        let checks: [(Double, [Double])] = [
            (Double(today.totalKeyPresses),       pastKeys),
            (Double(today.totalMouseClicks),      pastClicks),
            (today.totalMouseDistanceMillimeters, pastDistance),
            (Double(today.totalScrollTicks),      pastScrolls)
        ]

        for (current, history) in checks {
            // Only consider metrics with enough non-zero history. Days
            // without activity skew the median toward zero and would
            // fire on any ordinary workday.
            let samples = history.filter { $0 > 0 }
            guard samples.count >= minimumSamples else { continue }
            let median = Self.median(samples)
            guard median > 0 else { continue }
            let deviation = abs(current - median) / median
            if deviation > threshold { return true }
        }
        return false
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

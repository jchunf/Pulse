import Testing
import Foundation
@testable import PulseCore

@Suite("AnomalyDetector — today-vs-7-day-median ±30%")
struct AnomalyDetectorTests {

    private func point(_ day: Date, keys: Int = 0, clicks: Int = 0,
                       distanceMm: Double = 0, scrolls: Int = 0,
                       idle: Int = 0) -> DailyTrendPoint {
        DailyTrendPoint(
            day: day,
            keyPresses: keys,
            mouseClicks: clicks,
            mouseDistanceMillimeters: distanceMm,
            scrollTicks: scrolls,
            idleSeconds: idle
        )
    }

    private func summary(keys: Int = 0, clicks: Int = 0,
                         distanceMm: Double = 0, scrolls: Int = 0,
                         idle: Int = 0) -> TodaySummary {
        TodaySummary(
            totalKeyPresses: keys,
            totalMouseClicks: clicks,
            totalMouseMovesRaw: 0,
            totalMouseDistanceMillimeters: distanceMm,
            totalScrollTicks: scrolls,
            totalActiveSeconds: 0,
            totalIdleSeconds: idle,
            topApps: []
        )
    }

    @Test("flat week, today matches median → no anomaly")
    func noAnomalyWhenFlat() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let past = (0..<7).map { day in
            point(base.addingTimeInterval(Double(day) * 86_400),
                  keys: 10_000, clicks: 500, distanceMm: 1_000, scrolls: 50)
        }
        let today = summary(keys: 10_000, clicks: 500, distanceMm: 1_000, scrolls: 50)
        #expect(!AnomalyDetector.hasAnomaly(today: today, past: past))
    }

    @Test("today 50% above median on one metric → anomaly")
    func anomalyWhenHigh() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let past = (0..<7).map { day in
            point(base.addingTimeInterval(Double(day) * 86_400),
                  keys: 10_000, clicks: 500, distanceMm: 1_000)
        }
        // Keys up 50% (median 10_000, today 15_000 → +50%).
        let today = summary(keys: 15_000, clicks: 500, distanceMm: 1_000)
        #expect(AnomalyDetector.hasAnomaly(today: today, past: past))
    }

    @Test("today 50% below median on one metric → anomaly")
    func anomalyWhenLow() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let past = (0..<7).map { day in
            point(base.addingTimeInterval(Double(day) * 86_400),
                  keys: 10_000, distanceMm: 1_000)
        }
        let today = summary(keys: 4_000, distanceMm: 1_000)
        #expect(AnomalyDetector.hasAnomaly(today: today, past: past))
    }

    @Test("too-little history on every metric → no anomaly")
    func skipsUnderSampled() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Only 2 non-zero samples per metric; minimumSamples default is 3.
        let past = (0..<7).map { day -> DailyTrendPoint in
            if day < 2 {
                return point(base.addingTimeInterval(Double(day) * 86_400), keys: 10_000)
            }
            return point(base.addingTimeInterval(Double(day) * 86_400))
        }
        let today = summary(keys: 100_000) // way above, but not enough history to judge
        #expect(!AnomalyDetector.hasAnomaly(today: today, past: past))
    }

    @Test("within 30% deviation on every metric → no anomaly")
    func withinThreshold() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let past = (0..<7).map { day in
            point(base.addingTimeInterval(Double(day) * 86_400),
                  keys: 10_000, clicks: 500, distanceMm: 1_000, scrolls: 100)
        }
        // 25% above median on each metric — under the 30% threshold.
        let today = summary(keys: 12_500, clicks: 625, distanceMm: 1_250, scrolls: 125)
        #expect(!AnomalyDetector.hasAnomaly(today: today, past: past))
    }
}

import Testing
import Foundation
@testable import PulseCore

@Suite("InsightEngine — rule boundaries")
struct InsightEngineTests {

    // MARK: - Helpers

    /// Build a context that is below every rule's threshold by
    /// default. Individual tests bump the specific field they are
    /// exercising, which keeps the intent of each test case small.
    private func baselineContext(
        todayKeys: Int = 5_000,
        pastKeys: [Int] = [5_000, 5_100, 4_950, 5_050, 5_000, 5_100],
        todayActive: Int = 4 * 3_600,
        topApps: [AppUsageRow] = [
            AppUsageRow(bundleId: "com.example.work", secondsUsed: 2_000),
            AppUsageRow(bundleId: "com.example.other", secondsUsed: 1_500)
        ],
        todayFocus: FocusSegment? = nil,
        pastFocusSeconds: [Int] = []
    ) -> InsightContext {
        let today = TodaySummary(
            totalKeyPresses: todayKeys,
            totalMouseClicks: 500,
            totalMouseMovesRaw: 10_000,
            totalMouseDistanceMillimeters: 100_000,
            totalScrollTicks: 50,
            totalActiveSeconds: todayActive,
            totalIdleSeconds: 300,
            topApps: topApps
        )
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let pastTrend: [DailyTrendPoint] = pastKeys.enumerated().map { offset, keys in
            let day = calendar.date(
                byAdding: .day,
                value: -(pastKeys.count - offset),
                to: now
            ) ?? now
            return DailyTrendPoint(
                day: day,
                keyPresses: keys,
                mouseClicks: 0,
                mouseDistanceMillimeters: 0
            )
        }
        return InsightContext(
            today: today,
            pastDailyTrend: pastTrend,
            todayLongestFocus: todayFocus,
            pastLongestFocusSeconds: pastFocusSeconds
        )
    }

    // MARK: - ActivityAnomalyRule

    @Test("activity-anomaly — within band produces no insight")
    func activityAnomalyWithinBand() {
        let rule = ActivityAnomalyRule()
        // Today 5_000 vs median 5_050 — ~1% off, nowhere near 30%.
        let insight = rule.evaluate(context: baselineContext())
        #expect(insight == nil)
    }

    @Test("activity-anomaly — fires above threshold, direction=above")
    func activityAnomalyAbove() throws {
        let rule = ActivityAnomalyRule()
        let ctx = baselineContext(
            todayKeys: 8_000,
            pastKeys: [5_000, 5_100, 4_950, 5_050, 5_000, 5_100]
        )
        let insight = try #require(rule.evaluate(context: ctx))
        #expect(insight.id == "activity_anomaly")
        #expect(insight.kind == .curious)
        guard case let .activityAnomaly(direction, percentOff, todayKeys, medianKeys) = insight.payload else {
            Issue.record("wrong payload case: \(insight.payload)")
            return
        }
        #expect(direction == .above)
        #expect(todayKeys == 8_000)
        #expect(medianKeys == 5_025) // even-count median: (5000+5050)/2
        // (8000-5025)/5025 ≈ 59.2%
        #expect(percentOff == 59)
    }

    @Test("activity-anomaly — fires below threshold, direction=below")
    func activityAnomalyBelow() throws {
        let rule = ActivityAnomalyRule()
        let ctx = baselineContext(
            todayKeys: 2_500,
            pastKeys: [5_000, 5_000, 5_000, 5_000, 5_000, 5_000]
        )
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .activityAnomaly(direction, percentOff, _, medianKeys) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(direction == .below)
        #expect(medianKeys == 5_000)
        #expect(percentOff == 50)
    }

    @Test("activity-anomaly — silent under minimum history")
    func activityAnomalyMinimumHistory() {
        let rule = ActivityAnomalyRule() // minimumHistoryDays default = 3
        let ctx = baselineContext(
            todayKeys: 10_000,
            pastKeys: [5_000, 5_000] // only 2 non-zero — below floor
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("activity-anomaly — zero-activity prior days are excluded before median")
    func activityAnomalyDropsZeroHistory() throws {
        let rule = ActivityAnomalyRule(minimumHistoryDays: 3)
        // 3 valid days of 5_000, 3 zero days (Pulse off). Median of
        // the surviving non-zero set is 5_000 — not a diluted 2_500.
        let ctx = baselineContext(
            todayKeys: 8_000,
            pastKeys: [0, 0, 0, 5_000, 5_000, 5_000]
        )
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .activityAnomaly(_, percentOff, _, medianKeys) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(medianKeys == 5_000)
        #expect(percentOff == 60)
    }

    @Test("activity-anomaly — median below floor stays quiet")
    func activityAnomalyMedianFloor() {
        // Median 50 is below the default floor of 100 — a typo-sized
        // baseline doesn't justify "200% above normal" insights.
        let rule = ActivityAnomalyRule()
        let ctx = baselineContext(
            todayKeys: 500,
            pastKeys: [50, 40, 60, 55, 45, 50]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("activity-anomaly — today == 0 is silent (Pulse wasn't running)")
    func activityAnomalyTodayZero() {
        let rule = ActivityAnomalyRule()
        let ctx = baselineContext(
            todayKeys: 0,
            pastKeys: [5_000, 5_000, 5_000, 5_000, 5_000, 5_000]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    // MARK: - DeepFocusStandoutRule

    @Test("deep-focus — fires when today is ≥ 1.3× median")
    func deepFocusFires() throws {
        let rule = DeepFocusStandoutRule()
        let ctx = baselineContext(
            todayFocus: FocusSegment(
                bundleId: "com.apple.dt.Xcode",
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_000 + 60 * 60),
                durationSeconds: 60 * 60
            ),
            pastFocusSeconds: [30 * 60, 32 * 60, 28 * 60, 30 * 60, 34 * 60]
        )
        let insight = try #require(rule.evaluate(context: ctx))
        #expect(insight.kind == .celebratory)
        guard case let .deepFocusStandout(todaySec, medianSec, bundleId, percentAbove) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(todaySec == 3_600)
        #expect(medianSec == 30 * 60)
        #expect(bundleId == "com.apple.dt.Xcode")
        #expect(percentAbove == 100) // 3600 / 1800 − 1 = 1.0
    }

    @Test("deep-focus — quiet when today ties the median")
    func deepFocusAtMedian() {
        let rule = DeepFocusStandoutRule()
        let ctx = baselineContext(
            todayFocus: FocusSegment(
                bundleId: "app",
                startedAt: Date(),
                endedAt: Date(),
                durationSeconds: 30 * 60
            ),
            pastFocusSeconds: [30 * 60, 30 * 60, 30 * 60]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("deep-focus — below absolute minimum is quiet even if ratio is huge")
    func deepFocusMinimumDuration() {
        let rule = DeepFocusStandoutRule() // minimumTodaySeconds default 25 min
        let ctx = baselineContext(
            todayFocus: FocusSegment(
                bundleId: "app",
                startedAt: Date(),
                endedAt: Date(),
                durationSeconds: 20 * 60 // 20 min, under floor
            ),
            pastFocusSeconds: [5 * 60, 5 * 60, 5 * 60]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("deep-focus — no today focus → quiet")
    func deepFocusNoToday() {
        let rule = DeepFocusStandoutRule()
        let ctx = baselineContext(pastFocusSeconds: [30 * 60, 30 * 60, 30 * 60])
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("deep-focus — insufficient history → quiet")
    func deepFocusNoHistory() {
        let rule = DeepFocusStandoutRule()
        let ctx = baselineContext(
            todayFocus: FocusSegment(
                bundleId: "app",
                startedAt: Date(),
                endedAt: Date(),
                durationSeconds: 90 * 60
            ),
            pastFocusSeconds: [30 * 60] // only 1 day < minimumHistoryDays=3
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    // MARK: - SingleAppDominanceRule

    @Test("single-app — fires when top app > 50% of active time")
    func singleAppDominanceFires() throws {
        let rule = SingleAppDominanceRule()
        let ctx = baselineContext(
            todayActive: 4 * 3_600, // 14_400
            topApps: [
                AppUsageRow(bundleId: "com.apple.dt.Xcode", secondsUsed: 8_000),
                AppUsageRow(bundleId: "com.apple.Safari", secondsUsed: 3_000)
            ]
        )
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .singleAppDominance(bundleId, fraction, seconds) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(bundleId == "com.apple.dt.Xcode")
        #expect(seconds == 8_000)
        #expect(abs(fraction - (8_000.0 / 14_400.0)) < 0.0001)
    }

    @Test("single-app — quiet when no single app dominates")
    func singleAppNoDominance() {
        let rule = SingleAppDominanceRule()
        let ctx = baselineContext(
            todayActive: 4 * 3_600,
            topApps: [
                AppUsageRow(bundleId: "a", secondsUsed: 3_000),
                AppUsageRow(bundleId: "b", secondsUsed: 3_000),
                AppUsageRow(bundleId: "c", secondsUsed: 3_000)
            ]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("single-app — quiet under minimum active time")
    func singleAppUnderMinimumActive() {
        let rule = SingleAppDominanceRule() // minimumActiveSeconds default 30 min
        let ctx = baselineContext(
            todayActive: 10 * 60, // 10 min
            topApps: [
                AppUsageRow(bundleId: "a", secondsUsed: 9 * 60) // 90% of 10 min
            ]
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("single-app — quiet when top-apps list is empty")
    func singleAppEmpty() {
        let rule = SingleAppDominanceRule()
        let ctx = baselineContext(topApps: [])
        #expect(rule.evaluate(context: ctx) == nil)
    }

    // MARK: - InsightEngine integration

    @Test("engine — preserves rule registration order and drops nils")
    func engineOrdering() {
        let engine = InsightEngine(rules: [
            SingleAppDominanceRule(),
            ActivityAnomalyRule()
        ])
        let ctx = baselineContext(
            todayKeys: 10_000, // 98% above median 5_050, fires
            topApps: [
                AppUsageRow(bundleId: "solo", secondsUsed: 10_000) // >50% of 14_400
            ]
        )
        let insights = engine.evaluate(context: ctx)
        #expect(insights.count == 2)
        #expect(insights[0].id == "single_app_dominance")
        #expect(insights[1].id == "activity_anomaly")
    }

    @Test("engine — empty rule list returns empty array")
    func engineEmpty() {
        let engine = InsightEngine(rules: [])
        #expect(engine.evaluate(context: baselineContext()).isEmpty)
    }

    @Test("engine — defaults cover all three rules")
    func engineDefaults() {
        let engine = InsightEngine()
        let ruleIds = engine.rules.map(\.id)
        #expect(ruleIds == ["activity_anomaly", "deep_focus_standout", "single_app_dominance"])
    }

    // MARK: - Statistics helper

    @Test("median — odd length picks middle")
    func medianOdd() {
        #expect(InsightStatistics.median([3, 1, 2]) == 2)
        #expect(InsightStatistics.median([5]) == 5)
    }

    @Test("median — even length averages the two middles")
    func medianEven() {
        #expect(InsightStatistics.median([1, 2, 3, 4]) == 2) // (2+3)/2 with int division = 2
        #expect(InsightStatistics.median([10, 20]) == 15)
    }

    @Test("median — empty returns nil")
    func medianEmpty() {
        #expect(InsightStatistics.median([]) == nil)
    }
}

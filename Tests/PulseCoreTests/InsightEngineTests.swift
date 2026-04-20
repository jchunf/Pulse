import Testing
import Foundation
@testable import PulseCore

@Suite("InsightEngine — rule boundaries")
struct InsightEngineTests {

    // MARK: - Helpers

    /// A fixed reference "now" so hourly tests don't drift as wall-
    /// clock time changes between runs. 14:30 local means hours 0–13
    /// are considered "completed" and eligible for evaluation.
    private var referenceNow: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 19
        components.hour = 14; components.minute = 30
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

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
        pastFocusSeconds: [Int] = [],
        heatmapCells: [HeatmapCell] = [],
        now: Date? = nil
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
        let resolvedNow = now ?? Date()
        let calendar = Calendar(identifier: .gregorian)
        let pastTrend: [DailyTrendPoint] = pastKeys.enumerated().map { offset, keys in
            let day = calendar.date(
                byAdding: .day,
                value: -(pastKeys.count - offset),
                to: resolvedNow
            ) ?? resolvedNow
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
            pastLongestFocusSeconds: pastFocusSeconds,
            heatmapCells: heatmapCells,
            now: resolvedNow,
            calendar: utcCalendar
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

    // MARK: - HourlyActivityAnomalyRule

    /// Helper that builds the heatmap cells for a history of prior
    /// days + a single today cell at the given hour. Only hour 10
    /// is populated unless callers provide additional cells.
    private func heatmap(
        todayHour: Int = 10,
        todayCount: Int,
        pastDayCountsAtSameHour: [Int]
    ) -> [HeatmapCell] {
        var cells: [HeatmapCell] = [
            HeatmapCell(dayOffset: 0, hour: todayHour, activityCount: todayCount)
        ]
        for (index, count) in pastDayCountsAtSameHour.enumerated() where count > 0 {
            cells.append(
                HeatmapCell(
                    dayOffset: index + 1,
                    hour: todayHour,
                    activityCount: count
                )
            )
        }
        return cells
    }

    @Test("hourly — fires on the hour with largest magnitude deviation")
    func hourlyFires() throws {
        let rule = HourlyActivityAnomalyRule()
        let ctx = baselineContext(
            heatmapCells: heatmap(
                todayHour: 10,
                todayCount: 200,
                pastDayCountsAtSameHour: [80, 90, 75, 85, 80]
            ),
            now: referenceNow
        )
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .hourlyActivityAnomaly(hour, direction, percentOff, todayCount, medianCount) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(hour == 10)
        #expect(direction == .above)
        #expect(todayCount == 200)
        #expect(medianCount == 80)   // median of [75, 80, 80, 85, 90]
        #expect(percentOff == 150)   // (200-80)/80 * 100 = 150
    }

    @Test("hourly — fires on the quieter direction too")
    func hourlyFiresBelow() throws {
        let rule = HourlyActivityAnomalyRule()
        let ctx = baselineContext(
            heatmapCells: heatmap(
                todayHour: 9,
                todayCount: 30,
                pastDayCountsAtSameHour: [120, 110, 130, 115, 125]
            ),
            now: referenceNow
        )
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .hourlyActivityAnomaly(_, direction, percentOff, _, medianCount) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(direction == .below)
        #expect(medianCount == 120)  // median of [110, 115, 120, 125, 130]
        #expect(percentOff == 75)    // (120-30)/120 * 100 = 75
    }

    @Test("hourly — picks the biggest magnitude when multiple hours qualify")
    func hourlyPicksBiggest() throws {
        let rule = HourlyActivityAnomalyRule()
        var cells: [HeatmapCell] = []
        // Hour 9: +60% — qualifying but weaker.
        cells.append(HeatmapCell(dayOffset: 0, hour: 9, activityCount: 160))
        for d in 1...5 {
            cells.append(HeatmapCell(dayOffset: d, hour: 9, activityCount: 100))
        }
        // Hour 13: +200% — the clear winner.
        cells.append(HeatmapCell(dayOffset: 0, hour: 13, activityCount: 300))
        for d in 1...5 {
            cells.append(HeatmapCell(dayOffset: d, hour: 13, activityCount: 100))
        }
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .hourlyActivityAnomaly(hour, _, percentOff, _, _) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(hour == 13)
        #expect(percentOff == 200)
    }

    @Test("hourly — silent on hour not yet completed")
    func hourlyIgnoresIncompleteHour() {
        // currentHour = 14; hour 14 is in progress → rule must skip it.
        let rule = HourlyActivityAnomalyRule()
        let cells: [HeatmapCell] = [
            HeatmapCell(dayOffset: 0, hour: 14, activityCount: 500)
        ] + (1...5).map {
            HeatmapCell(dayOffset: $0, hour: 14, activityCount: 100)
        }
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("hourly — silent when history too sparse")
    func hourlyInsufficientHistory() {
        let rule = HourlyActivityAnomalyRule() // minimumHistoryDays default 3
        let cells: [HeatmapCell] = [
            HeatmapCell(dayOffset: 0, hour: 10, activityCount: 200),
            HeatmapCell(dayOffset: 1, hour: 10, activityCount: 100),
            HeatmapCell(dayOffset: 2, hour: 10, activityCount: 100)
            // only 2 prior days — below floor
        ]
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("hourly — silent when same-hour median is below medianFloor")
    func hourlyMedianFloor() {
        let rule = HourlyActivityAnomalyRule() // medianFloor default 30
        let cells: [HeatmapCell] = [
            HeatmapCell(dayOffset: 0, hour: 10, activityCount: 300)
        ] + (1...5).map {
            HeatmapCell(dayOffset: $0, hour: 10, activityCount: 10) // median 10 < 30
        }
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("hourly — silent when today has no cell (Pulse may be off)")
    func hourlyTodayMissing() {
        let rule = HourlyActivityAnomalyRule()
        let cells: [HeatmapCell] = (1...5).map {
            HeatmapCell(dayOffset: $0, hour: 10, activityCount: 100)
        }
        // Today has no hour-10 cell at all.
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("hourly — silent at midnight when no hours have completed")
    func hourlyEarlyMorning() {
        let rule = HourlyActivityAnomalyRule()
        // 00:30 — currentHour = 0; no completed hours yet.
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 19
        components.hour = 0; components.minute = 30
        components.timeZone = TimeZone(identifier: "UTC")
        let midnight30 = utcCalendar.date(from: components)!
        let ctx = baselineContext(
            heatmapCells: heatmap(
                todayHour: 10, // irrelevant — no hour < 0
                todayCount: 200,
                pastDayCountsAtSameHour: [80, 90, 75, 85, 80]
            ),
            now: midnight30
        )
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("hourly — within band produces no insight")
    func hourlyWithinBand() {
        let rule = HourlyActivityAnomalyRule() // thresholdPercent 50
        let cells: [HeatmapCell] = [
            HeatmapCell(dayOffset: 0, hour: 10, activityCount: 90) // 12.5% above median 80
        ] + (1...5).map {
            HeatmapCell(dayOffset: $0, hour: 10, activityCount: 80)
        }
        let ctx = baselineContext(heatmapCells: cells, now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    // MARK: - StreakAtRiskRule

    /// Build a minimal `InsightContext` exercising only streak fields.
    /// Past-days run old → new; today is appended last. `activeHoursPastDay`
    /// controls whether each past day qualifies (≥ 4 by default).
    private func streakContext(
        pastQualifiedDays: Int,
        todayActiveHours: Int,
        hourOfDay: Int = 16
    ) -> InsightContext {
        let today = TodaySummary(
            totalKeyPresses: 1,
            totalMouseClicks: 0,
            totalMouseMovesRaw: 0,
            totalMouseDistanceMillimeters: 0,
            totalScrollTicks: 0,
            totalActiveSeconds: 0,
            totalIdleSeconds: 0,
            topApps: []
        )
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 19
        components.hour = hourOfDay; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let now = utcCalendar.date(from: components)!
        let todayStart = utcCalendar.startOfDay(for: now)
        // Past days + today as ContinuityDay cells.
        var days: [ContinuityDay] = []
        for offset in stride(from: pastQualifiedDays, to: 0, by: -1) {
            let day = utcCalendar.date(byAdding: .day, value: -offset, to: todayStart)!
            days.append(ContinuityDay(day: day, activeHours: 8, qualified: true))
        }
        days.append(ContinuityDay(
            day: todayStart,
            activeHours: todayActiveHours,
            qualified: todayActiveHours >= 4
        ))
        let streak = ContinuityStreak(
            days: days,
            currentStreak: days.last?.qualified == true ? pastQualifiedDays + 1 : 0,
            longestStreak: pastQualifiedDays + (days.last?.qualified == true ? 1 : 0),
            qualifyingDays: pastQualifiedDays + (days.last?.qualified == true ? 1 : 0),
            windowDays: days.count
        )
        return InsightContext(
            today: today,
            pastDailyTrend: [],
            todayLongestFocus: nil,
            pastLongestFocusSeconds: [],
            heatmapCells: [],
            continuity: streak,
            now: now,
            calendar: utcCalendar
        )
    }

    @Test("streak-at-risk — fires when 7-day streak hanging + today unqualified + post-15:00")
    func streakAtRiskFires() throws {
        let rule = StreakAtRiskRule()
        let ctx = streakContext(pastQualifiedDays: 7, todayActiveHours: 2)
        let insight = try #require(rule.evaluate(context: ctx))
        #expect(insight.id == "streak_at_risk")
        #expect(insight.kind == .celebratory)
        guard case let .streakAtRisk(currentStreak, activeHoursToday, hoursToQualify) = insight.payload else {
            Issue.record("wrong payload case: \(insight.payload)")
            return
        }
        #expect(currentStreak == 7)
        #expect(activeHoursToday == 2)
        #expect(hoursToQualify == 2) // 4 - 2
    }

    @Test("streak-at-risk — silent when continuity is nil")
    func streakAtRiskNilContinuity() {
        let rule = StreakAtRiskRule()
        let ctx = baselineContext(now: referenceNow)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("streak-at-risk — silent when today already qualified")
    func streakAtRiskTodayQualified() {
        let rule = StreakAtRiskRule()
        let ctx = streakContext(pastQualifiedDays: 10, todayActiveHours: 6)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("streak-at-risk — silent when today has zero activity (streak already gone)")
    func streakAtRiskTodayZero() {
        let rule = StreakAtRiskRule()
        let ctx = streakContext(pastQualifiedDays: 10, todayActiveHours: 0)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("streak-at-risk — silent before the mid-afternoon cutoff")
    func streakAtRiskEarly() {
        let rule = StreakAtRiskRule() // hourOfDayToFire default 15
        let ctx = streakContext(pastQualifiedDays: 10, todayActiveHours: 2, hourOfDay: 11)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("streak-at-risk — silent when prior streak is below the minimum")
    func streakAtRiskShortStreak() {
        let rule = StreakAtRiskRule() // minimumStreakDays default 7
        let ctx = streakContext(pastQualifiedDays: 5, todayActiveHours: 2)
        #expect(rule.evaluate(context: ctx) == nil)
    }

    @Test("streak-at-risk — 7 exactly qualifies (boundary)")
    func streakAtRiskBoundary() throws {
        let rule = StreakAtRiskRule(minimumStreakDays: 7)
        let ctx = streakContext(pastQualifiedDays: 7, todayActiveHours: 1)
        let insight = try #require(rule.evaluate(context: ctx))
        guard case let .streakAtRisk(currentStreak, _, hoursToQualify) = insight.payload else {
            Issue.record("wrong payload case")
            return
        }
        #expect(currentStreak == 7)
        #expect(hoursToQualify == 3)
    }

    @Test("streak-at-risk — ignores gaps in prior window; current streak measured through yesterday")
    func streakAtRiskGapStops() {
        let rule = StreakAtRiskRule()
        let today = TodaySummary(
            totalKeyPresses: 1,
            totalMouseClicks: 0,
            totalMouseMovesRaw: 0,
            totalMouseDistanceMillimeters: 0,
            totalScrollTicks: 0,
            totalActiveSeconds: 0,
            totalIdleSeconds: 0,
            topApps: []
        )
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 19
        components.hour = 16; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let now = utcCalendar.date(from: components)!
        let todayStart = utcCalendar.startOfDay(for: now)
        // A 10-day block, but with a break right before yesterday so
        // the through-yesterday streak is only 3 — below the default
        // minimum of 7 even though the overall longest is bigger.
        var days: [ContinuityDay] = []
        for offset in stride(from: 15, to: 0, by: -1) {
            let day = utcCalendar.date(byAdding: .day, value: -offset, to: todayStart)!
            let qualified = offset <= 3 || (offset >= 5 && offset <= 12)
            days.append(ContinuityDay(day: day, activeHours: qualified ? 8 : 1, qualified: qualified))
        }
        days.append(ContinuityDay(day: todayStart, activeHours: 2, qualified: false))
        let streak = ContinuityStreak(
            days: days,
            currentStreak: 0,
            longestStreak: 8,
            qualifyingDays: 11,
            windowDays: days.count
        )
        let ctx = InsightContext(
            today: today,
            pastDailyTrend: [],
            todayLongestFocus: nil,
            pastLongestFocusSeconds: [],
            heatmapCells: [],
            continuity: streak,
            now: now,
            calendar: utcCalendar
        )
        // Through-yesterday streak is 3 (offsets 3, 2, 1 qualified) —
        // below the default 7, so the rule stays silent.
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

    @Test("engine — defaults cover every registered rule in declared order")
    func engineDefaults() {
        let engine = InsightEngine()
        let ruleIds = engine.rules.map(\.id)
        #expect(ruleIds == [
            "streak_at_risk",
            "hourly_activity_anomaly",
            "deep_focus_standout",
            "single_app_dominance",
            "activity_anomaly"
        ])
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

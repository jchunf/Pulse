import Testing
import Foundation
@testable import PulseCore

@Suite("GoalEvaluator — today's measurements vs target")
struct GoalEvaluatorTests {

    private func summary(
        keys: Int = 0,
        active: Int = 0
    ) -> TodaySummary {
        TodaySummary(
            totalKeyPresses: keys,
            totalMouseClicks: 0,
            totalMouseMovesRaw: 0,
            totalMouseDistanceMillimeters: 0,
            totalScrollTicks: 0,
            totalActiveSeconds: active,
            totalIdleSeconds: 0,
            topApps: []
        )
    }

    @Test("atLeast goal below target is not achieved and fills proportionally")
    func atLeastHalfway() {
        let goal = GoalDefinition(
            id: "x",
            metric: .activeSeconds,
            direction: .atLeast,
            target: 10_000
        )
        let results = GoalEvaluator.evaluate(
            goals: [goal],
            summary: summary(active: 5_000),
            longestFocus: nil,
            appSwitchesToday: nil
        )
        let r = results[0]
        #expect(!r.isAchieved)
        #expect(r.actualValue == 5_000)
        #expect(abs(r.fractionTowardsTarget - 0.5) < 0.0001)
    }

    @Test("atLeast goal at or above target reads as achieved and clamps bar to 1")
    func atLeastAchievedClamps() {
        let goal = GoalDefinition(
            id: "x",
            metric: .keystrokes,
            direction: .atLeast,
            target: 1_000
        )
        let results = GoalEvaluator.evaluate(
            goals: [goal],
            summary: summary(keys: 5_000),
            longestFocus: nil,
            appSwitchesToday: nil
        )
        let r = results[0]
        #expect(r.isAchieved)
        #expect(r.fractionTowardsTarget == 1.0) // clamped
    }

    @Test("atMost goal with usage well under target is achieved and shows full bar")
    func atMostWithinBudget() {
        let goal = GoalDefinition(
            id: "x",
            metric: .appSwitches,
            direction: .atMost,
            target: 30
        )
        let results = GoalEvaluator.evaluate(
            goals: [goal],
            summary: summary(),
            longestFocus: nil,
            appSwitchesToday: 10
        )
        let r = results[0]
        #expect(r.isAchieved)
        #expect(r.fractionTowardsTarget == 1.0)  // under budget → full "good" bar
        #expect(r.actualValue == 10)
    }

    @Test("atMost goal exceeded drops progress bar to empty")
    func atMostOverrun() {
        let goal = GoalDefinition(
            id: "x",
            metric: .appSwitches,
            direction: .atMost,
            target: 30
        )
        let results = GoalEvaluator.evaluate(
            goals: [goal],
            summary: summary(),
            longestFocus: nil,
            appSwitchesToday: 60  // 2× target
        )
        let r = results[0]
        #expect(!r.isAchieved)
        #expect(r.fractionTowardsTarget == 0) // 1 - (2-1) = 0, clamped
    }

    @Test("longestFocusSeconds pulls value from the focus segment")
    func focusMetricPullsFromSegment() {
        let goal = GoalDefinition(
            id: "x",
            metric: .longestFocusSeconds,
            direction: .atLeast,
            target: 30 * 60
        )
        let segment = FocusSegment(
            bundleId: "com.apple.dt.Xcode",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(45 * 60),
            durationSeconds: 45 * 60
        )
        let results = GoalEvaluator.evaluate(
            goals: [goal],
            summary: summary(),
            longestFocus: segment,
            appSwitchesToday: nil
        )
        let r = results[0]
        #expect(r.isAchieved)
        #expect(r.actualValue == Double(45 * 60))
    }

    @Test("missing app switch count falls back to zero")
    func missingSwitchesCountsAsZero() {
        let atLeast = GoalDefinition(
            id: "a", metric: .appSwitches,
            direction: .atLeast, target: 10
        )
        let atMost = GoalDefinition(
            id: "b", metric: .appSwitches,
            direction: .atMost, target: 10
        )
        let results = GoalEvaluator.evaluate(
            goals: [atLeast, atMost],
            summary: summary(),
            longestFocus: nil,
            appSwitchesToday: nil
        )
        // atLeast 10 with actual 0 → not achieved
        #expect(!results[0].isAchieved)
        // atMost 10 with actual 0 → achieved (you didn't exceed)
        #expect(results[1].isAchieved)
    }
}

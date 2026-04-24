import Testing
import Foundation
@testable import PulseCore

@Suite("ThresholdAlertEvaluator — local fatigue / screen-time alerts (F-45)")
struct ThresholdAlertTests {

    @Test("disabled thresholds never fire")
    func disabledSettingsSuppressesEverything() {
        let settings = ThresholdAlertSettings()  // both nil
        let metrics = ThresholdAlertMetrics(
            activeSecondsToday: 12 * 60 * 60,
            continuousActiveSeconds: 6 * 60 * 60
        )
        let out = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: metrics,
            memory: ThresholdAlertMemory()
        )
        #expect(out.isEmpty)
    }

    @Test("screen-time alert fires when crossed")
    func screenTimeAlertFires() {
        let settings = ThresholdAlertSettings(
            screenTimeSecondsThreshold: 8 * 60 * 60,
            noBreakSecondsThreshold: nil
        )
        let metrics = ThresholdAlertMetrics(
            activeSecondsToday: 9 * 60 * 60,
            continuousActiveSeconds: nil
        )
        let out = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: metrics,
            memory: ThresholdAlertMemory()
        )
        #expect(out.count == 1)
        if case let .screenTimeExceeded(threshold, actual) = out[0] {
            #expect(threshold == 28_800)
            #expect(actual == 32_400)
        } else {
            Issue.record("expected .screenTimeExceeded")
        }
    }

    @Test("already-fired kinds are suppressed")
    func memoryPreventsDoubleFire() {
        let settings = ThresholdAlertSettings.defaults
        let metrics = ThresholdAlertMetrics(
            activeSecondsToday: 9 * 60 * 60,
            continuousActiveSeconds: 3 * 60 * 60
        )
        let memory = ThresholdAlertMemory(
            firedKinds: ["screenTimeExceeded", "noBreakSince"]
        )
        let out = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: metrics,
            memory: memory
        )
        #expect(out.isEmpty)
    }

    @Test("no-break alert needs continuous active seconds")
    func noBreakRequiresContinuous() {
        let settings = ThresholdAlertSettings(
            screenTimeSecondsThreshold: nil,
            noBreakSecondsThreshold: 2 * 60 * 60
        )
        // continuous is nil (user currently idle) → no fire
        let nilOut = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: ThresholdAlertMetrics(activeSecondsToday: 10_000, continuousActiveSeconds: nil),
            memory: ThresholdAlertMemory()
        )
        #expect(nilOut.isEmpty)
        // continuous below threshold → no fire
        let belowOut = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: ThresholdAlertMetrics(activeSecondsToday: 10_000, continuousActiveSeconds: 3_600),
            memory: ThresholdAlertMemory()
        )
        #expect(belowOut.isEmpty)
        // continuous crosses → fires
        let acrossOut = ThresholdAlertEvaluator.evaluate(
            settings: settings,
            metrics: ThresholdAlertMetrics(activeSecondsToday: 10_000, continuousActiveSeconds: 7_500),
            memory: ThresholdAlertMemory()
        )
        #expect(acrossOut.count == 1)
    }

    @Test("both kinds can fire on the same tick")
    func bothKindsOnSameTick() {
        let out = ThresholdAlertEvaluator.evaluate(
            settings: .defaults,
            metrics: ThresholdAlertMetrics(
                activeSecondsToday: 10 * 60 * 60,
                continuousActiveSeconds: 3 * 60 * 60
            ),
            memory: ThresholdAlertMemory()
        )
        #expect(out.count == 2)
        let ids = out.map(\.identifier)
        #expect(ids.contains("screenTimeExceeded"))
        #expect(ids.contains("noBreakSince"))
    }
}

@Suite("ContinuousActiveDeriver — 'no break' input derivation (F-45)")
struct ContinuousActiveDeriverTests {

    private let dayStart = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("no rest segments → elapsed since dayStart")
    func noRestSinceDayStart() {
        let now = dayStart.addingTimeInterval(7_200)
        let out = ContinuousActiveDeriver.derive(
            restSegments: [],
            dayStart: dayStart,
            now: now
        )
        #expect(out == 7_200)
    }

    @Test("rest ended well before now → elapsed since rest end")
    func elapsedSinceLastRest() {
        let restEnd = dayStart.addingTimeInterval(3_600)
        let now = dayStart.addingTimeInterval(9_000)
        let out = ContinuousActiveDeriver.derive(
            restSegments: [(dayStart, restEnd)],
            dayStart: dayStart,
            now: now
        )
        #expect(out == 5_400)  // 9000 - 3600
    }

    @Test("rest still open at now → nil (user currently idle)")
    func stillIdleReturnsNil() {
        let now = dayStart.addingTimeInterval(5_000)
        // Rest ended within the 30-second grace window of now.
        let restEnd = now.addingTimeInterval(-10)
        let out = ContinuousActiveDeriver.derive(
            restSegments: [(dayStart.addingTimeInterval(3_000), restEnd)],
            dayStart: dayStart,
            now: now
        )
        #expect(out == nil)
    }
}

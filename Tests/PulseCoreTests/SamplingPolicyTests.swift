import Testing
import Foundation
@testable import PulseCore
import PulseTestSupport

@Suite("SamplingPolicy — adaptive throttle for raw events")
struct SamplingPolicyTests {

    @Test("first event is always recorded")
    func firstEventRecorded() {
        let clock = FakeClock()
        let policy = SamplingPolicy(clock: clock)
        #expect(policy.shouldRecord(at: clock.now) == true)
    }

    @Test("at active rate, events spaced shorter than 1/rate are dropped")
    func dropsAtActiveRate() {
        let clock = FakeClock()
        let policy = SamplingPolicy(
            clock: clock,
            configuration: .init(activeRateHz: 30, idleRateHz: 1, idleWindow: 60)
        )
        // First event: accepted.
        #expect(policy.shouldRecord(at: clock.now) == true)
        // 0.01s later (above 30Hz spacing): dropped.
        clock.advance(0.01)
        #expect(policy.shouldRecord(at: clock.now) == false)
        // Wait full 1/30s: accepted.
        clock.advance(1.0 / 30.0)
        #expect(policy.shouldRecord(at: clock.now) == true)
    }

    @Test("after idleWindow elapses with no activity, fall back to idle rate")
    func fallsBackToIdleRate() {
        let clock = FakeClock()
        let policy = SamplingPolicy(
            clock: clock,
            configuration: .init(activeRateHz: 30, idleRateHz: 1, idleWindow: 5)
        )
        // Prime with an active event.
        _ = policy.shouldRecord(at: clock.now)
        // Wait beyond the idle window so the next event sees idleness.
        clock.advance(10)
        // First event after gap: accepted.
        #expect(policy.shouldRecord(at: clock.now) == true)
        // 0.5s later at idle rate (1Hz): too soon, dropped.
        clock.advance(0.5)
        #expect(policy.shouldRecord(at: clock.now) == false)
        // 1s later: accepted.
        clock.advance(0.6)
        #expect(policy.shouldRecord(at: clock.now) == true)
    }

    @Test("activity reverts to active rate the moment it resumes")
    func resumeRestoresActive() {
        let clock = FakeClock()
        let policy = SamplingPolicy(
            clock: clock,
            configuration: .init(activeRateHz: 30, idleRateHz: 1, idleWindow: 5)
        )
        _ = policy.shouldRecord(at: clock.now)
        clock.advance(10)
        _ = policy.shouldRecord(at: clock.now)
        // 0.05s later — exceeds 1/30 spacing, well within active window
        // because the previous event re-marked activity.
        clock.advance(0.05)
        #expect(policy.shouldRecord(at: clock.now) == true)
    }
}

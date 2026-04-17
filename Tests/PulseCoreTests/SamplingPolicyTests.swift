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

    @Test("first event after an idleWindow gap is classified as idle-rate but always accepted")
    func firstPostIdleEventAccepted() {
        let clock = FakeClock()
        let policy = SamplingPolicy(
            clock: clock,
            configuration: .init(activeRateHz: 30, idleRateHz: 1, idleWindow: 5)
        )
        // Prime.
        _ = policy.shouldRecord(at: clock.now)
        // Wait beyond idleWindow. The next event is classified as idle (gap
        // since lastActivity ≥ idleWindow), evaluated at idleRate 1 Hz, and
        // always accepted because the lastAccepted gap is 10s ≫ 1/1 Hz.
        clock.advance(10)
        #expect(policy.shouldRecord(at: clock.now) == true)
    }

    @Test("once activity resumes, sampling re-evaluates as active (gap-based)")
    func resumedActivityIsActive() {
        // Documents that SamplingPolicy is gap-based, not sticky-idle: the
        // FIRST event after a long gap uses idleRate, but subsequent events
        // within idleWindow of that event are classified active again and
        // throttled at activeRate. This matches the design in
        // docs/04-architecture.md#4.2: "drop to 1 Hz when no events for N s".
        let clock = FakeClock()
        let policy = SamplingPolicy(
            clock: clock,
            configuration: .init(activeRateHz: 30, idleRateHz: 1, idleWindow: 5)
        )
        _ = policy.shouldRecord(at: clock.now)
        clock.advance(10)
        _ = policy.shouldRecord(at: clock.now)
        // 0.5s later: gap < idleWindow ⇒ active rate ⇒ 0.5s > 1/30 s ⇒ accepted.
        clock.advance(0.5)
        #expect(policy.shouldRecord(at: clock.now) == true)
        // 1 ms later: still active, but 1 ms < 1/30 s ⇒ dropped.
        clock.advance(0.001)
        #expect(policy.shouldRecord(at: clock.now) == false)
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

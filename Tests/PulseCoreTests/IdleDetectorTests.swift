import Testing
import Foundation
@testable import PulseCore
import PulseTestSupport

@Suite("IdleDetector — 5-minute inactivity state machine")
struct IdleDetectorTests {

    private func makeDetector(thresholdSeconds: TimeInterval = 300) -> (IdleDetector, FakeClock) {
        let clock = FakeClock()
        let detector = IdleDetector(clock: clock, idleThresholdSeconds: thresholdSeconds)
        return (detector, clock)
    }

    @Test("fresh detector reports not idle")
    func startsNotIdle() {
        let (detector, _) = makeDetector()
        #expect(detector.state.isIdle == false)
    }

    @Test("tick within threshold produces no transition")
    func tickBeforeThreshold() {
        let (detector, clock) = makeDetector()
        clock.advance(60)
        #expect(detector.tick(now: clock.now) == nil)
    }

    @Test("tick at exactly threshold emits idleEntered")
    func tickAtThreshold() {
        let (detector, clock) = makeDetector()
        clock.advance(300)
        let transition = detector.tick(now: clock.now)
        #expect(transition == .idleEntered(at: clock.now))
        #expect(detector.state.isIdle == true)
    }

    @Test("multiple ticks after idle do not re-emit idleEntered")
    func noDuplicateIdleEntered() {
        let (detector, clock) = makeDetector()
        clock.advance(300)
        _ = detector.tick(now: clock.now)
        clock.advance(60)
        #expect(detector.tick(now: clock.now) == nil)
    }

    @Test("activity after idle emits idleExited")
    func activityWakesFromIdle() {
        let (detector, clock) = makeDetector()
        clock.advance(300)
        _ = detector.tick(now: clock.now)
        clock.advance(1)
        let transition = detector.observe(.keyPress(keyCode: nil, at: clock.now))
        #expect(transition == .idleExited(at: clock.now))
        #expect(detector.state.isIdle == false)
    }

    @Test("non-activity events do not wake from idle")
    func nonActivityDoesNotWake() {
        let (detector, clock) = makeDetector()
        clock.advance(300)
        _ = detector.tick(now: clock.now)
        let transition = detector.observe(
            .foregroundApp(bundleId: "com.apple.Finder", at: clock.now)
        )
        #expect(transition == nil)
        #expect(detector.state.isIdle == true)
    }

    @Test("activity stream prevents idle from firing")
    func activityResetsTimer() {
        let (detector, clock) = makeDetector()
        for _ in 0..<10 {
            clock.advance(60)
            let transition = detector.observe(.keyPress(keyCode: nil, at: clock.now))
            #expect(transition == nil)
            #expect(detector.tick(now: clock.now) == nil)
        }
        #expect(detector.state.isIdle == false)
    }

    @Test("configurable threshold respected")
    func customThreshold() {
        let (detector, clock) = makeDetector(thresholdSeconds: 10)
        clock.advance(10)
        #expect(detector.tick(now: clock.now) == .idleEntered(at: clock.now))
    }

    @Test("initial lastActivityAt equals clock.now at construction")
    func initialStateMatchesClock() {
        let clock = FakeClock()
        let detector = IdleDetector(clock: clock)
        #expect(detector.state.lastActivityAt == clock.now)
    }
}

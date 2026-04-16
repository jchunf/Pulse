import Testing
import Foundation
@testable import PulseCore
import PulseTestSupport

@Suite("PauseController — pause windows and auto-resume")
struct PauseControllerTests {

    @Test("fresh controller is not paused")
    func startsActive() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        #expect(controller.isPaused(at: clock.now) == false)
        #expect(controller.snapshot().isActive == false)
    }

    @Test("pause(reason:duration:) blocks events for the requested window")
    func pauseBlocksEvents() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .userPause, duration: 60)
        #expect(controller.isPaused(at: clock.now) == true)
        clock.advance(30)
        #expect(controller.isPaused(at: clock.now) == true)
    }

    @Test("auto-resume occurs at the deadline")
    func autoResume() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .userPause, duration: 60)
        clock.advance(60)
        #expect(controller.isPaused(at: clock.now) == false)
        #expect(controller.snapshot().isActive == false)
    }

    @Test("explicit resume clears immediately")
    func explicitResume() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .userPause, duration: 600)
        controller.resume()
        #expect(controller.isPaused(at: clock.now) == false)
    }

    @Test("longer pause wins when overlapping")
    func longerWins() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .userPause, duration: 60)
        controller.pause(reason: .sensitivePeriod, duration: 30)
        clock.advance(40)
        #expect(controller.isPaused(at: clock.now) == true, "30s overrideing 60s would resume early")
    }

    @Test("snapshot reports pause reason")
    func snapshotReason() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .sensitivePeriod, duration: 120)
        #expect(controller.snapshot().reason == .sensitivePeriod)
    }

    @Test("snapshot self-clears after deadline")
    func snapshotSelfClears() {
        let clock = FakeClock()
        let controller = PauseController(clock: clock)
        controller.pause(reason: .userPause, duration: 60)
        clock.advance(120)
        let state = controller.snapshot()
        #expect(state.isActive == false)
        #expect(state.reason == nil)
        #expect(state.resumesAt == nil)
    }
}

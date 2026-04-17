#if canImport(AppKit)
import Testing
import Foundation
import PulseCore
import PulseTestSupport
@testable import PulsePlatform

/// IOKit can't be exercised on a CI runner — no real lid, no real power
/// transitions — so these tests cover the wiring between
/// `LidPowerObserver`'s emit path and the caller's handler. The `simulate*`
/// hooks bypass IOKit and route through the same internal `emit(_:)`.
@Suite("LidPowerObserver — handler wiring")
struct LidPowerObserverTests {

    @Test("simulateLidChanged delivers lidClosed and lidOpened to handler")
    func lidEventsReachHandler() async throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = LidPowerObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateLidChanged(open: false, at: clock.now)
        clock.advance(1)
        observer.simulateLidChanged(open: true, at: clock.now)
        observer.stop()

        let events = collector.events
        #expect(events.count == 2)
        #expect(events.first.map { isLidClosed($0) } == true)
        #expect(events.last.map { isLidOpened($0) } == true)
    }

    @Test("simulatePowerChanged delivers powerChanged with payload")
    func powerEventsReachHandler() async throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = LidPowerObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulatePowerChanged(isOnBattery: true, percent: 87, at: clock.now)
        observer.stop()

        let events = collector.events
        #expect(events.count == 1)
        if case let .powerChanged(isOnBattery, percent, _) = events.first {
            #expect(isOnBattery == true)
            #expect(percent == 87)
        } else {
            Issue.record("expected powerChanged event")
        }
    }

    @Test("stop clears handler so post-stop simulations are ignored")
    func stopDetachesHandler() async throws {
        let observer = LidPowerObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.stop()
        observer.simulateLidChanged(open: false)
        #expect(collector.events.isEmpty)
    }

    private func isLidClosed(_ event: DomainEvent) -> Bool {
        if case .lidClosed = event { return true }
        return false
    }

    private func isLidOpened(_ event: DomainEvent) -> Bool {
        if case .lidOpened = event { return true }
        return false
    }
}

/// Thread-safe collector for AppKit-delivered events.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DomainEvent] = []

    func append(_ event: DomainEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }

    var events: [DomainEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
#endif

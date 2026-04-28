#if canImport(AppKit)
import Testing
import Foundation
import PulseCore
import PulseTestSupport
@testable import PulsePlatform

/// F-32 — `ClipboardObserver` exposes a `simulateChangeCount(from:to:)`
/// hook so unit tests can pretend the system pasteboard's
/// `changeCount` advanced without touching `NSPasteboard`. The observer
/// itself never reads pasteboard content; these tests confirm the
/// emit-per-increment counting is correct and that the handler is
/// detached on `stop()`.
@Suite("ClipboardObserver — handler wiring")
struct ClipboardObserverTests {

    @Test("single increment delivers one .clipboardChanged")
    func singleIncrement() async throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = ClipboardObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.simulateChangeCount(from: 7, to: 8)
        observer.stop()

        let events = collector.events
        #expect(events.count == 1)
        if case .clipboardChanged = events.first {
            // ok
        } else {
            Issue.record("expected .clipboardChanged event")
        }
    }

    @Test("burst delivers one event per increment")
    func burstIncrement() async throws {
        let observer = ClipboardObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.simulateChangeCount(from: 100, to: 105)
        observer.stop()

        #expect(collector.events.count == 5)
        #expect(collector.events.allSatisfy {
            if case .clipboardChanged = $0 { return true }
            return false
        })
    }

    @Test("no-op when destination is not greater than source")
    func nonIncreasing() async throws {
        let observer = ClipboardObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.simulateChangeCount(from: 5, to: 5)
        observer.simulateChangeCount(from: 10, to: 3)  // pasteboard reset is impossible in practice but we guard
        observer.stop()
        #expect(collector.events.isEmpty)
    }

    @Test("stop detaches handler so post-stop simulations are ignored")
    func stopDetaches() async throws {
        let observer = ClipboardObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.stop()
        observer.simulateChangeCount(from: 1, to: 2)
        #expect(collector.events.isEmpty)
    }
}

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

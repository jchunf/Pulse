#if canImport(AppKit)
import Testing
import Foundation
import PulseCore
import PulseTestSupport
@testable import PulsePlatform

/// AX observers can't be exercised on a CI runner — no granted accessibility
/// access, no GUI session — so these tests cover the dedup + emit path that
/// the real AX callback funnels into. Tests pump synthesized events via
/// `simulateTitleChanged(bundleId:titleSHA256:)`.
@Suite("AccessibilityTitleObserver — dedup and handler wiring")
struct AccessibilityTitleObserverTests {

    @Test("first title for a bundle is emitted")
    func firstTitleEmits() {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = AccessibilityTitleObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.stop()

        #expect(collector.events.count == 1)
    }

    @Test("identical consecutive titles are deduped")
    func identicalTitleDeduped() {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = AccessibilityTitleObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.stop()

        #expect(collector.events.count == 1)
    }

    @Test("different hash within the same bundle is emitted")
    func newHashEmits() {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = AccessibilityTitleObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "BBB")
        observer.stop()

        #expect(collector.events.count == 2)
    }

    @Test("same hash across different bundles is emitted")
    func sameHashDifferentBundleEmits() {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let observer = AccessibilityTitleObserver(clock: clock)
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.simulateTitleChanged(bundleId: "com.apple.Mail", titleSHA256: "AAA")
        observer.stop()

        #expect(collector.events.count == 2)
    }

    @Test("resetDedupCacheForTesting allows re-emit of the same hash")
    func resetCacheReEmits() {
        let observer = AccessibilityTitleObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }

        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.resetDedupCacheForTesting()
        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
        observer.stop()

        #expect(collector.events.count == 2)
    }

    @Test("stop clears handler so post-stop simulations are ignored")
    func stopDetachesHandler() {
        let observer = AccessibilityTitleObserver()
        let collector = EventCollector()
        observer.start { event in collector.append(event) }
        observer.stop()
        observer.simulateTitleChanged(bundleId: "com.apple.Safari", titleSHA256: "AAA")
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

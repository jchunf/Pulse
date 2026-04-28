#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore

/// F-32 — observes the system pasteboard and emits a `.clipboardChanged`
/// `DomainEvent` every time `NSPasteboard.general.changeCount`
/// increases. The collector **never reads pasteboard content** — only
/// the integer changeCount is observed, which is incremented by the
/// system whenever anything is copied or cut.
///
/// **Privacy posture**:
/// - Reads `NSPasteboard.general.changeCount` only — an `Int`. Never
///   calls `string(forType:)` / `data(forType:)` / `pasteboardItems`
///   or any other content-accessing API.
/// - No TCC permission required (changeCount access is unprivileged).
/// - No new onboarding card.
/// - Disclosure in `docs/05-privacy.md` §4.3 (which already restricted
///   us to "frequency only" — F-32 implements that promise).
///
/// **Cadence**: polls every 2 seconds. Lightweight (one Int read per
/// tick); doesn't drain battery. The `idle_seconds` heuristic in
/// `min_idle` already covers the case where the user steps away —
/// detected pasteboard changes during a long idle gap mean another
/// app on the system did the copy (background utilities), which is
/// itself information.
public final class ClipboardObserver: @unchecked Sendable {

    private let clock: Clock
    private let pollInterval: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    /// Last observed changeCount. `nil` = never sampled. The first
    /// sample establishes the baseline; emits start on subsequent
    /// increments.
    private var lastChangeCount: Int?

    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(clock: Clock = SystemClock(), pollInterval: TimeInterval = 2.0) {
        self.clock = clock
        self.pollInterval = pollInterval
        self.queue = DispatchQueue(label: "com.pulse.ClipboardObserver", qos: .utility)
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop() {
        lock.lock()
        let t = self.timer
        self.timer = nil
        self.handler = nil
        lock.unlock()
        t?.cancel()
    }

    /// Test hook — pretend the pasteboard changeCount went from
    /// `from` to `to` and observe the resulting events.
    public func simulateChangeCount(from: Int, to: Int) {
        lock.lock()
        lastChangeCount = from
        let sink = handler
        lock.unlock()
        if to > from, let sink = sink {
            for _ in 0..<(to - from) {
                sink(.clipboardChanged(at: clock.now))
            }
        }
        lock.lock()
        lastChangeCount = to
        lock.unlock()
    }

    /// Emit one `.clipboardChanged` per increment between samples
    /// (so a burst of copies inside a single poll interval shows up
    /// as multiple events instead of being collapsed to one). The
    /// changeCount is a process-wide monotonic Int — increments are
    /// the only meaningful signal.
    private func tick() {
        let current = NSPasteboard.general.changeCount
        lock.lock()
        let prior = lastChangeCount
        lastChangeCount = current
        let sink = handler
        lock.unlock()
        guard let prior = prior else {
            return  // First sample — establish baseline only.
        }
        guard current > prior, let sink = sink else { return }
        let delta = current - prior
        let now = clock.now
        for _ in 0..<delta {
            sink(.clipboardChanged(at: now))
        }
    }
}
#endif

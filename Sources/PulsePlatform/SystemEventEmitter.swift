#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore

/// Emits `DomainEvent`s for system-level state transitions that don't
/// originate from `CGEventTap`: sleep/wake, screens sleep/wake, and
/// lock/unlock. The runtime persists these into `system_events` so the
/// HealthPanel and later reports can tell "my laptop was closed for 40
/// minutes" apart from "I was idle at the keyboard for 40 minutes".
///
/// Observers are scoped to the instance's lifetime; `stop()` tears them
/// down. Notifications are delivered on a private serial queue so the
/// handler executes off the main thread.
public final class SystemEventEmitter: @unchecked Sendable {

    private let clock: Clock
    private let queue: OperationQueue
    private var tearDowns: [() -> Void] = []
    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
        self.queue = OperationQueue()
        self.queue.name = "com.pulse.SystemEventEmitter"
        self.queue.qualityOfService = .utility
        self.queue.maxConcurrentOperationCount = 1
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard tearDowns.isEmpty else { return }
        self.handler = handler

        let ws = NSWorkspace.shared.notificationCenter
        subscribe(ws, name: NSWorkspace.willSleepNotification) { now in .systemSleep(at: now) }
        subscribe(ws, name: NSWorkspace.didWakeNotification)    { now in .systemWake(at: now) }
        // Screen sleep ≈ display off. Map to screenLocked/Unlocked so B4
        // doesn't need a separate event type — the downstream payload is
        // "screen is no longer contributing activity".
        subscribe(ws, name: NSWorkspace.screensDidSleepNotification) { now in .screenLocked(at: now) }
        subscribe(ws, name: NSWorkspace.screensDidWakeNotification)  { now in .screenUnlocked(at: now) }

        // macOS emits actual lock/unlock via distributed notifications on
        // legacy names. Register them separately so the emitter catches the
        // explicit screenlock event too.
        let dnc = DistributedNotificationCenter.default()
        subscribe(dnc, name: Notification.Name("com.apple.screenIsLocked"))   { now in .screenLocked(at: now) }
        subscribe(dnc, name: Notification.Name("com.apple.screenIsUnlocked")) { now in .screenUnlocked(at: now) }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        for teardown in tearDowns { teardown() }
        tearDowns.removeAll()
        handler = nil
    }

    // MARK: - Private

    // DistributedNotificationCenter inherits from NotificationCenter, so
    // one overload covers both.
    private func subscribe(
        _ center: NotificationCenter,
        name: Notification.Name,
        make: @escaping @Sendable (Date) -> DomainEvent
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: queue) { [weak self] _ in
            self?.emit(make)
        }
        tearDowns.append { [weak center] in center?.removeObserver(token) }
    }

    private func emit(_ make: @Sendable (Date) -> DomainEvent) {
        let handlerCopy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        handlerCopy = self.handler
        lock.unlock()
        guard let handlerCopy else { return }
        handlerCopy(make(clock.now))
    }
}
#endif

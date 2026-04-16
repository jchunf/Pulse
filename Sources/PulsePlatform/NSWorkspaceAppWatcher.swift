#if canImport(AppKit)
import AppKit
import PulseCore
import Foundation

/// Emits `.foregroundApp` events whenever the active application changes.
/// Thin wrapper over `NSWorkspace.didActivateApplicationNotification`; does
/// not need Input Monitoring (only Accessibility, and only for window
/// titles which arrive in a later PR).
public final class NSWorkspaceAppWatcher: @unchecked Sendable {

    private let clock: Clock
    private let queue: OperationQueue
    private var observer: NSObjectProtocol?
    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
        self.queue = OperationQueue()
        self.queue.name = "com.pulse.NSWorkspaceAppWatcher"
        self.queue.qualityOfService = .utility
        self.queue.maxConcurrentOperationCount = 1
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard observer == nil else { return }
        self.handler = handler
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: queue
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        handler = nil
    }

    private func handleActivation(_ notification: Notification) {
        let handlerCopy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        handlerCopy = self.handler
        lock.unlock()
        guard let handler = handlerCopy else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            return
        }
        handler(.foregroundApp(bundleId: bundleId, at: clock.now))
    }
}
#endif

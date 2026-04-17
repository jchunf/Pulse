#if canImport(AppKit)
import AppKit
import PulseCore
import Foundation

/// Emits `.foregroundApp` events whenever the active application changes.
/// When a non-nil `windowReader` is supplied, also emits a follow-up
/// `.windowTitleHash` event built from the new frontmost window's title.
///
/// Privacy: titles are only ever stored as SHA-256; force-redacted apps
/// (Messages / 1Password / etc.) emit a sentinel hash. See
/// `docs/05-privacy.md#4.2` and `AccessibilityWindowReader`.
public final class NSWorkspaceAppWatcher: @unchecked Sendable {

    private let clock: Clock
    private let windowReader: AccessibilityWindowReader?
    private let queue: OperationQueue
    private var observer: NSObjectProtocol?
    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(
        clock: Clock = SystemClock(),
        windowReader: AccessibilityWindowReader? = AccessibilityWindowReader()
    ) {
        self.clock = clock
        self.windowReader = windowReader
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

        let now = clock.now
        handler(.foregroundApp(bundleId: bundleId, at: now))

        if let windowReader, let titleEvent = windowReader.readFrontmostWindowEvent(for: app, at: now) {
            handler(titleEvent)
        }
    }
}
#endif

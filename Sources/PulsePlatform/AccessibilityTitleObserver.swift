#if canImport(AppKit)
import AppKit
import ApplicationServices
import Foundation
import PulseCore

/// Observes window title changes within the currently-frontmost app via
/// `AXObserver` and emits `windowTitleHash` events. Complements
/// `NSWorkspaceAppWatcher`, which only re-reads the title when the user
/// switches apps; this observer catches title changes that happen *inside*
/// the same app — e.g. switching browser tabs, opening a new document.
///
/// Lifecycle:
///   - `start()` subscribes to `NSWorkspace.didActivateApplicationNotification`
///     and immediately attaches an `AXObserver` to the current frontmost app.
///   - On every app activation, the previous AX observer is torn down and a
///     new one is attached for the new app.
///   - The AX observer registers for `kAXTitleChangedNotification` on the
///     focused window plus `kAXFocusedWindowChangedNotification` on the app
///     element, so document switches re-target title observation.
///
/// Same-hash dedup: titles within a single app frequently re-fire the AX
/// notification with the same value (e.g. an unsaved-document indicator
/// flickering). We compare the new hash against the last emitted one for
/// the same bundle and drop duplicates so `system_events` stays clean.
///
/// Runtime is `@MainActor` in practice — AX observers must be attached to a
/// `CFRunLoop` and we use the main run loop. `start()` and `stop()` are
/// expected to be called from the main thread.
public final class AccessibilityTitleObserver: @unchecked Sendable {

    private let clock: Clock
    private let reader: AccessibilityWindowReader

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedApp: NSRunningApplication?
    private var observedAppElement: AXUIElement?
    private var observedFocusedWindow: AXUIElement?

    private var lastEmittedBundleId: String?
    private var lastEmittedHash: String?

    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(
        clock: Clock = SystemClock(),
        reader: AccessibilityWindowReader = AccessibilityWindowReader()
    ) {
        self.clock = clock
        self.reader = reader
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock()
        guard workspaceObserver == nil else { lock.unlock(); return }
        self.handler = handler
        lock.unlock()

        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }
        lock.lock()
        workspaceObserver = token
        lock.unlock()

        if let front = NSWorkspace.shared.frontmostApplication {
            attachObserver(for: front)
            if let event = reader.readFrontmostWindowEvent(for: front, at: clock.now) {
                emitDeduped(event)
            }
        }
    }

    public func stop() {
        lock.lock()
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserver = nil
        detachObserverLocked()
        handler = nil
        lastEmittedBundleId = nil
        lastEmittedHash = nil
        lock.unlock()
    }

    // MARK: - Test hooks
    //
    // Tests can't drive a real `AXObserver` on CI (no accessibility grant,
    // no GUI). These hooks pump synthesized title events through the same
    // dedup + emit path the AX callback uses, so the wiring between
    // observer and handler is exercised end-to-end.

    /// Synthesize a title-change event and route it through the dedup path.
    public func simulateTitleChanged(
        bundleId: String,
        titleSHA256: String,
        at instant: Date? = nil
    ) {
        let when = instant ?? clock.now
        emitDeduped(.windowTitleHash(appBundleId: bundleId, titleSHA256: titleSHA256, at: when))
    }

    /// Forget the last emitted hash so the next `simulateTitleChanged` will
    /// re-emit even if the value is identical.
    public func resetDedupCacheForTesting() {
        lock.lock()
        lastEmittedBundleId = nil
        lastEmittedHash = nil
        lock.unlock()
    }

    // MARK: - Private

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attachObserver(for: app)
        if let event = reader.readFrontmostWindowEvent(for: app, at: clock.now) {
            emitDeduped(event)
        }
    }

    private func attachObserver(for app: NSRunningApplication) {
        lock.lock(); defer { lock.unlock() }
        detachObserverLocked()
        let pid = app.processIdentifier
        guard pid > 0 else { return }

        var observer: AXObserver?
        let createStatus = AXObserverCreate(pid, axTitleObserverCallback, &observer)
        guard createStatus == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, context)

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef {
            let window = focused as! AXUIElement
            AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, context)
            observedFocusedWindow = window
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObserver = observer
        observedApp = app
        observedAppElement = appElement
    }

    private func detachObserverLocked() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        axObserver = nil
        observedApp = nil
        observedAppElement = nil
        observedFocusedWindow = nil
    }

    fileprivate func handleAXNotification(notification: CFString) {
        let name = notification as String
        lock.lock()
        let app = observedApp
        lock.unlock()
        guard let app else { return }

        if name == (kAXFocusedWindowChangedNotification as String) {
            // Re-target the title observer at the new focused window and
            // emit a fresh hash for it.
            attachObserver(for: app)
            if let event = reader.readFrontmostWindowEvent(for: app, at: clock.now) {
                emitDeduped(event)
            }
        } else if name == (kAXTitleChangedNotification as String) {
            if let event = reader.readFrontmostWindowEvent(for: app, at: clock.now) {
                emitDeduped(event)
            }
        }
    }

    private func emitDeduped(_ event: DomainEvent) {
        guard case let .windowTitleHash(bundleId, hash, _) = event else {
            emit(event)
            return
        }
        lock.lock()
        let isDuplicate = (bundleId == lastEmittedBundleId && hash == lastEmittedHash)
        if !isDuplicate {
            lastEmittedBundleId = bundleId
            lastEmittedHash = hash
        }
        lock.unlock()
        guard !isDuplicate else { return }
        emit(event)
    }

    private func emit(_ event: DomainEvent) {
        let copy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        copy = handler
        lock.unlock()
        copy?(event)
    }
}

// AX callbacks must be plain C functions; bridge through retained context.
private func axTitleObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let me = Unmanaged<AccessibilityTitleObserver>.fromOpaque(refcon).takeUnretainedValue()
    me.handleAXNotification(notification: notification)
}
#endif

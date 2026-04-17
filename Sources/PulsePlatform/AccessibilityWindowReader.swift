#if canImport(AppKit)
import AppKit
import ApplicationServices
import PulseCore
import Foundation

/// Reads the title of the frontmost window via Accessibility APIs and
/// translates it into a `windowTitleHash` event using `TitleHasher`. The
/// raw title is **never** retained or logged — once hashed, the only
/// surviving artifact is `(bundleId, sha256)`.
///
/// Polled on demand (e.g. after `NSWorkspace` activation events) rather
/// than on a timer; we don't want to read titles when the user hasn't
/// changed apps. `B3` adds Title-change observation via AX notifications.
public struct AccessibilityWindowReader: Sendable {

    private let hasher: TitleHasher
    private let forceRedactBundleIds: Set<String>

    public init(
        hasher: TitleHasher = TitleHasher(),
        forceRedactBundleIds: Set<String> = AccessibilityWindowReader.defaultForceRedacts
    ) {
        self.hasher = hasher
        self.forceRedactBundleIds = forceRedactBundleIds
    }

    /// Apps whose window titles are *never* recorded — even hashed. The
    /// app identity (via `foregroundApp`) is enough; titles in these
    /// applications are presumed personal.
    public static let defaultForceRedacts: Set<String> = [
        "com.apple.Messages",
        "com.apple.iChat",
        "com.apple.mail",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "WhatsApp",
        "ru.keepcoder.Telegram",
        "org.signal.macos.Signal"
    ]

    /// Returns a `windowTitleHash` event for the frontmost window of the
    /// given app, or `nil` if titles cannot be read or the app is on the
    /// force-redact list. Caller is responsible for emitting the event into
    /// the runtime.
    public func readFrontmostWindowEvent(for app: NSRunningApplication, at instant: Date) -> DomainEvent? {
        guard let bundleId = app.bundleIdentifier else { return nil }

        if forceRedactBundleIds.contains(bundleId) {
            return .windowTitleHash(
                appBundleId: bundleId,
                titleSHA256: TitleHasher.forceRedactedSentinel,
                at: instant
            )
        }

        let pid = app.processIdentifier
        guard pid > 0 else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        )
        guard focusedStatus == .success, let focused = focusedRef else { return nil }

        let element = focused as! AXUIElement
        var titleRef: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        guard titleStatus == .success,
              let title = titleRef as? String,
              !title.isEmpty else {
            return nil
        }

        return .windowTitleHash(
            appBundleId: bundleId,
            titleSHA256: hasher.hash(title),
            at: instant
        )
    }
}
#endif

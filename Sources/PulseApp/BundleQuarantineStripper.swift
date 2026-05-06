#if canImport(AppKit)
import AppKit
import Foundation

/// Strips macOS Gatekeeper's `com.apple.quarantine` extended attribute
/// from this .app bundle and everything nested inside it. Called once
/// from `AppDelegate.applicationDidFinishLaunching`.
///
/// **Why this exists.** Pulse is ad-hoc signed (no Developer ID, no
/// notarization). When a user downloads `Pulse.dmg` or `Pulse.zip`
/// from the browser, macOS marks the file with `com.apple.quarantine`.
/// Dragging the .app into `/Applications` propagates the attribute to
/// every file inside the bundle — including Sparkle's
/// `Installer.xpc` / `Updater.app` / `Autoupdate` helpers.
///
/// When Sparkle later tries to launch one of those helpers via XPC
/// (during a "Check for updates…" → install flow), macOS Gatekeeper
/// blocks the launch because the helper is quarantined and not
/// notarized. The XPC channel never opens, Sparkle's invalidation
/// handler fires, and the user sees:
///
///     SUSparkleErrorDomain #4005 — "remote port connection
///     invalidated from the updater"
///     Underlying: SUSparkleErrorDomain #10 — "Failed to start
///     installer"
///
/// The error message Sparkle hard-codes for this case mentions
/// ad-hoc / team-id matching as a possible cause, which is a red
/// herring — the real reason is Gatekeeper rejecting the
/// quarantined helper. (See PR series #155 / #156 / this PR.)
///
/// **What this does.** Walks the bundle root and every descendant
/// path with `removexattr` to clear `com.apple.quarantine`. Idempotent
/// — paths without the attribute are left unchanged.
///
/// **Why we run it on every launch.** New `.zip` / `.dmg` downloads
/// re-introduce quarantine on the just-installed bundle. Re-stripping
/// on every launch makes the next Sparkle install attempt
/// quarantine-clean even after a manual reinstall.
enum BundleQuarantineStripper {

    private static let attribute = "com.apple.quarantine"

    /// Strip the quarantine attribute from `bundlePath` and every
    /// file underneath it. Returns the count of paths that had the
    /// attribute removed (for diagnostic logging — see
    /// `lastStripCount`).
    @discardableResult
    static func strip(at bundlePath: String) -> Int {
        var stripped = 0
        if removeAttribute(at: bundlePath) { stripped += 1 }
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: bundlePath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if removeAttribute(at: url.path) { stripped += 1 }
            }
        }
        UserDefaults.standard.set(stripped, forKey: lastStripCountKey)
        UserDefaults.standard.set(Date(), forKey: lastStripAtKey)
        UserDefaults.standard.set(bundlePath, forKey: lastBundlePathKey)
        return stripped
    }

    /// Diagnostic surfaces — read by `DiagnosticsCard` so the user
    /// can confirm at a glance whether the quarantine attribute is
    /// still showing up on this bundle. `lastStripCount > 0` means
    /// the bundle had quarantine residues stripped on the most
    /// recent launch; `0` means the bundle was already clean.
    static let lastStripCountKey = "pulse.update.lastQuarantineStripCount"
    static let lastStripAtKey = "pulse.update.lastQuarantineStripAt"
    static let lastBundlePathKey = "pulse.update.bundlePath"

    /// `removexattr` returns 0 on success, -1 with errno = ENOATTR
    /// when the attribute wasn't present (treated as "no work
    /// needed"). Any other failure (typically EPERM in a sandbox we
    /// don't have, or EROFS on a read-only volume) is logged
    /// implicitly via the Diagnostics surface — there's no further
    /// recovery to attempt.
    private static func removeAttribute(at path: String) -> Bool {
        return path.withCString { cPath in
            // XATTR_NOFOLLOW: don't follow symlinks. Sparkle.framework
            // contains symlinks (Versions/Current → B); we want to
            // strip the attribute on the symlink itself, not on the
            // target (which the enumerator will visit separately).
            let rc = removexattr(cPath, attribute, XATTR_NOFOLLOW)
            return rc == 0
        }
    }
}
#endif

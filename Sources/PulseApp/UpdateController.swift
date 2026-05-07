#if canImport(AppKit)
import AppKit
import Foundation
import Sparkle

/// Wraps `SPUStandardUpdaterController` so the rest of the app only
/// sees a `checkForUpdates()` entry point. The controller is owned
/// by `AppDelegate` and lives for the lifetime of the app.
///
/// Privacy posture matches `docs/05-privacy.md` §七 verbatim — update
/// checks are **strictly user-initiated**:
///
/// - `Info.plist` sets `SUEnableAutomaticChecks = false`,
///   `SUAllowsAutomaticUpdates = false`, `SUScheduledCheckInterval = 0`.
/// - At runtime we also call `updater.automaticallyChecksForUpdates =
///   false` as a belt-and-braces guard against a Sparkle default ever
///   flipping under us.
/// - `sendsSystemProfile = false` stops Sparkle from attaching CPU /
///   macOS / locale metadata to the check; we only want the fact of
///   "is there a newer version?".
///
/// **History note**: PRs #138-#159 in v2.0.x tried to ship a "dev
/// channel" toggle that switched Sparkle's feed URL between the
/// stable appcast and a rolling dev-latest one. The cross-channel
/// install path repeatedly hit `SUSparkleErrorDomain #4005` on
/// ad-hoc-signed builds for reasons that took five PRs to fully
/// understand (the final root cause: codesign autogenerating an
/// `<filename>-<hash>` identifier on the bare `Autoupdate` Mach-O
/// when re-signing without `--preserve-metadata`). The dev channel
/// itself was a power-user surface that wasn't worth the
/// maintenance overhead, so it was removed entirely. This file
/// now only routes Sparkle's stable feed (baked into Info.plist
/// `SUFeedURL`) — no channel selection, no delegate version
/// comparator. The `BundleSigningInspector` and the captured
/// abort-error trace stay because they're cheap, they help debug
/// any future stable update that misbehaves, and they're invisible
/// when nothing's wrong.
@MainActor
final class UpdateController {

    /// The underlying `SPUStandardUpdaterController`. Public so a
    /// `CommandMenu` / keyboard-shortcut binding can connect directly
    /// to `updater.checkForUpdates` in SwiftUI later; today we expose
    /// a single wrapper method and leave that open.
    let updaterController: SPUStandardUpdaterController

    /// Retained on purpose — `SPUStandardUpdaterController` holds the
    /// delegate weakly, so if we let this go out of scope the error
    /// capture path silently stops working.
    private let delegate: PulseUpdaterDelegate

    init() {
        self.delegate = PulseUpdaterDelegate()
        // `startingUpdater: true` instantiates the underlying
        // `SPUUpdater` and starts its scheduler *loop*, but because
        // `SUEnableAutomaticChecks` is false that loop is inert — it
        // just waits for a manual call to `checkForUpdates`.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self.delegate,
            userDriverDelegate: nil
        )
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = false
        updater.sendsSystemProfile = false
    }

    /// User-initiated entry point. Wires into the menu-bar and
    /// Settings buttons. Shows the standard Sparkle UI (progress,
    /// release notes, restart prompt) on success; shows an error
    /// dialog if the feed is unreachable or the signature check
    /// fails.
    ///
    /// Routes through `SPUStandardUpdaterController.checkForUpdates(_:)`
    /// (the `@IBAction` surface) rather than the bare `SPUUpdater`
    /// method so the "check for updates" menu-validation path stays
    /// consistent with what Sparkle's docs recommend.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

/// Minimal `SPUUpdaterDelegate`. The only thing we plumb through is
/// abort-error capture — everything Sparkle needs comes from
/// `Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
/// etc.). The captured error surfaces in Settings → Diagnostics so a
/// user reporting "Check for updates is broken" can paste a precise
/// trace instead of fishing through Console.app.
final class PulseUpdaterDelegate: NSObject, SPUUpdaterDelegate {

    /// Stable UserDefaults keys for the last-update-error trace.
    /// Read by `DiagnosticsCard` so the card can render the captured
    /// info.
    static let lastUpdateErrorKey = "pulse.update.lastError"
    static let lastUpdateErrorAtKey = "pulse.update.lastErrorAt"

    /// Fires when Sparkle's update cycle ends, regardless of outcome
    /// (user installed, user dismissed, network error, signature
    /// failure). On error: capture the trace. On clean cycle: clear
    /// any prior captured error so the Diagnostics card stops
    /// surfacing stale failures after the user fixes the underlying
    /// issue.
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            captureUpdateError(error)
        } else {
            clearCapturedUpdateError()
        }
    }

    /// Sparkle calls this when the cycle aborts before completion
    /// (network failure, signature mismatch, installer-launcher
    /// failure, etc.).
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        captureUpdateError(error)
    }

    private func captureUpdateError(_ error: Error) {
        let nsError = error as NSError
        var lines: [String] = []
        lines.append("\(nsError.domain) #\(nsError.code)")
        lines.append(nsError.localizedDescription)
        if let reason = nsError.localizedFailureReason {
            lines.append("Reason: \(reason)")
        }
        if let suggestion = nsError.localizedRecoverySuggestion {
            lines.append("Suggestion: \(suggestion)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underNS = underlying as NSError
            lines.append("Underlying: \(underNS.domain) #\(underNS.code) — \(underNS.localizedDescription)")
        }
        UserDefaults.standard.set(lines.joined(separator: " · "), forKey: Self.lastUpdateErrorKey)
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateErrorAtKey)
    }

    private func clearCapturedUpdateError() {
        UserDefaults.standard.removeObject(forKey: Self.lastUpdateErrorKey)
        UserDefaults.standard.removeObject(forKey: Self.lastUpdateErrorAtKey)
    }
}
#endif

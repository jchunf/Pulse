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
/// The `SPUStandardUpdaterController` uses the standard SwiftUI / AppKit
/// update UI: modal with release notes, progress bar, restart prompt.
/// We deliberately do not implement `SPUUpdaterDelegate` — the default
/// behaviour (feed URL from `SUFeedURL`, EdDSA verification from
/// `SUPublicEDKey`) is exactly what PR β will wire in.
@MainActor
final class UpdateController {

    /// The underlying `SPUStandardUpdaterController`. Public so a
    /// `CommandMenu` / keyboard-shortcut binding can connect directly
    /// to `updater.checkForUpdates` in SwiftUI later; today we expose
    /// a single wrapper method and leave that open.
    let updaterController: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` instantiates the underlying
        // `SPUUpdater` and starts its scheduler *loop*, but because
        // `SUEnableAutomaticChecks` is false that loop is inert — it
        // just waits for a manual call to `checkForUpdates`.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
#endif

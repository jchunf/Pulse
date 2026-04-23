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
/// Channel routing: the delegate's `feedURLString(for:)` picks between
/// the stable feed (baked into Info.plist `SUFeedURL`) and the dev
/// feed (baked into `SUDevFeedURL`) based on `UserDefaults.standard`
/// key `pulse.update.channel`. Flipping the toggle in Settings →
/// About changes which feed the next "Check for updates…" hits.
@MainActor
final class UpdateController {

    /// The underlying `SPUStandardUpdaterController`. Public so a
    /// `CommandMenu` / keyboard-shortcut binding can connect directly
    /// to `updater.checkForUpdates` in SwiftUI later; today we expose
    /// a single wrapper method and leave that open.
    let updaterController: SPUStandardUpdaterController

    /// Retained on purpose — `SPUStandardUpdaterController` holds the
    /// delegate weakly, so if we let this go out of scope the channel
    /// switch silently stops working.
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

/// Picks between stable and dev Sparkle feeds on every update check.
///
/// Sparkle calls `feedURLString(for:)` immediately before each fetch,
/// so this reflects the user's latest toggle state without needing a
/// restart. Returning `nil` falls back to `SUFeedURL` in Info.plist —
/// the canonical stable path, so forks that only set `SUFeedURL`
/// keep working even if they never ship a dev feed.
final class PulseUpdaterDelegate: NSObject, SPUUpdaterDelegate {

    /// UserDefaults key bound to the Settings toggle. String-typed
    /// ("stable" | "dev") rather than bool so a future "beta" channel
    /// can slot in without migrating the key.
    static let channelKey = "pulse.update.channel"
    static let stableChannel = "stable"
    static let devChannel = "dev"

    /// Info.plist key holding the dev appcast URL. Kept out of the
    /// Swift sources so the URL lives alongside `SUFeedURL` and
    /// `SUPublicEDKey` — one place to retarget when forking.
    static let devFeedInfoKey = "SUDevFeedURL"

    func feedURLString(for _: SPUUpdater) -> String? {
        // Sparkle may call this off the main actor; `UserDefaults` and
        // `Bundle.main` reads are thread-safe.
        let channel = UserDefaults.standard.string(forKey: Self.channelKey)
            ?? Self.stableChannel
        guard channel == Self.devChannel else {
            // Stable: nil hands control back to Sparkle, which reads
            // `SUFeedURL` from Info.plist.
            return nil
        }
        if let devURL = Bundle.main.object(forInfoDictionaryKey: Self.devFeedInfoKey) as? String,
           !devURL.isEmpty {
            return devURL
        }
        // Dev feed missing from Info.plist (forks, ad-hoc builds) —
        // fail back to stable so the user isn't stranded.
        return nil
    }
}
#endif

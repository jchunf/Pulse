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
///
/// Cross-channel switching: `switchChannel(to:)` is the
/// AppDelegate-facing entry point that handles the
/// stable↔dev jump when the user flips the toggle. Sparkle's "newer
/// `sparkle:version` wins" rule normally prevents a 12_000_001-build
/// stable user from being pulled to a 240-build dev item — channels
/// filter candidates, not direction. We work around it by feeding
/// Sparkle a one-shot `SUVersionComparison` that pretends the new
/// channel's item is always newer; the delegate clears the override
/// the moment Sparkle finishes the update cycle, so within-channel
/// updates revert to the standard "newer wins" semantics immediately
/// after.
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

    /// Switch the user to the opposite channel and immediately offer
    /// the latest item from that channel as an "update". Called when
    /// the Settings → About toggle is flipped — the user expects
    /// "ON = dev" / "OFF = stable" to *do* the switch, not just
    /// change a preference.
    ///
    /// Sequence:
    ///   1. Persist the new channel preference (the toggle binding
    ///      may already have done this, but call it again for the
    ///      direct `switchChannel(to:)` callers — `AppDelegate` may
    ///      route from a future menu shortcut, etc.).
    ///   2. Mark the next check as "force-newer" so the version
    ///      comparator below short-circuits the build-number compare.
    ///   3. Trigger a normal `checkForUpdates()`. Sparkle sees an
    ///      "available" item, prompts the standard install flow,
    ///      EdDSA-verifies the download, swaps the .app, restarts.
    ///
    /// If the user dismisses Sparkle's prompt, the channel preference
    /// stays flipped (no rollback) — they intended the switch and
    /// dismissing the install dialog just means "not right now". The
    /// force-newer flag clears either way.
    func switchChannel(to newChannel: String) {
        UserDefaults.standard.set(newChannel, forKey: PulseUpdaterDelegate.channelKey)
        delegate.armForceNextCheck()
        checkForUpdates()
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

    /// Process-memory force-newer flag. Set by `armForceNextCheck()`
    /// right before `UpdateController` triggers a check; cleared by
    /// `updater(_:didFinishUpdateCycleFor:error:)` when Sparkle
    /// finishes (success, dismiss, or error). Deliberately NOT
    /// persisted — if the app crashes mid-check, the user re-toggles
    /// from a clean state on the next launch rather than inheriting
    /// a stale "always-newer" override.
    private let forceLock = NSLock()
    private var _forceNewerForNextCheck = false

    fileprivate func armForceNextCheck() {
        forceLock.lock(); defer { forceLock.unlock() }
        _forceNewerForNextCheck = true
    }

    private func clearForceNextCheck() {
        forceLock.lock(); defer { forceLock.unlock() }
        _forceNewerForNextCheck = false
    }

    private var isForceNewerArmed: Bool {
        forceLock.lock(); defer { forceLock.unlock() }
        return _forceNewerForNextCheck
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        // Sparkle may call this off the main actor; `UserDefaults` and
        // `Bundle.main` reads are thread-safe.
        guard isDevChannel else {
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

    /// Filters appcast items by `<sparkle:channel>` tag. Returning
    /// `["dev"]` when the toggle is on means a single feed could carry
    /// both dev and stable items and the right ones would surface;
    /// today the feeds are separate (see `feedURLString(for:)`), but
    /// implementing the delegate also future-proofs us — splicing
    /// items across feeds is now safe to revisit. The empty-set case
    /// (toggle off) lets through items with no channel tag, which is
    /// the convention for "stable" in Sparkle 2.x.
    ///
    /// History note: pre-v1.1.6 we tagged stable items with
    /// `<sparkle:channel>stable</sparkle:channel>` and shipped no
    /// `allowedChannels` delegate, so every item got filtered out
    /// and "Check for updates…" silently said you were current. The
    /// 1.1.6 fix was to strip the tag everywhere; this restoration
    /// is paired with the matching delegate so the same trap doesn't
    /// reopen.
    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        isDevChannel ? [Self.devChannel] : []
    }

    /// One-shot version-compare override. Active only between
    /// `armForceNextCheck()` and the matching
    /// `didFinishUpdateCycleFor:` callback below. While armed, the
    /// candidate feed item always reads as "newer" than the current
    /// build, so Sparkle offers it for install regardless of the
    /// asymmetric BUILD encoding (stable BUILD ~10⁷ vs dev BUILD ~10²
    /// — without this hook, dev→stable goes through naturally but
    /// stable→dev hits "you're already on a newer version").
    func versionComparator(for _: SPUUpdater) -> (any SUVersionComparison)? {
        guard isForceNewerArmed else { return nil }
        return AlwaysNewerComparator()
    }

    /// Fires when Sparkle's update cycle ends, regardless of outcome
    /// (user installed, user dismissed, network error, signature
    /// failure). Clearing here means the force-override is scoped
    /// exactly to the cycle that `armForceNextCheck()` armed; the
    /// next manual "Check for updates…" goes through the standard
    /// version-compare path.
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        clearForceNextCheck()
    }

    private var isDevChannel: Bool {
        let channel = UserDefaults.standard.string(forKey: Self.channelKey)
            ?? Self.stableChannel
        return channel == Self.devChannel
    }
}

/// Always reports the candidate as newer than the current. Used as a
/// one-shot version comparator during a cross-channel switch — see
/// `PulseUpdaterDelegate.versionComparator(for:)`. Sparkle invokes
/// this for every appcast item, so when armed we end up with all of
/// the new channel's items as candidates; combined with channel
/// filtering, the "best" item is the latest one in the new channel.
final class AlwaysNewerComparator: NSObject, SUVersionComparison {
    func compareVersion(_ versionA: String, toVersion versionB: String) -> ComparisonResult {
        // Sparkle compares (currentVersion, candidateVersion) and
        // accepts when the result is `.orderedAscending`
        // (currentVersion < candidateVersion). Returning that
        // unconditionally turns every appcast item into "this is
        // newer, install it".
        .orderedAscending
    }
}
#endif

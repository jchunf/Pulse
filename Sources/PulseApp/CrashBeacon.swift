#if canImport(AppKit)
import AppKit
import Combine
import Foundation

/// F-49b — "did Pulse exit cleanly last time?" beacon.
///
/// Pulse is `LSUIElement` (no Dock icon, no crash dialog). When the
/// app crashes overnight the user only knows by noticing the
/// menu-bar icon is gone. This class detects a previous-session
/// crash on the next launch and publishes `crashedLastSession =
/// true` so the Dashboard can surface a non-intrusive banner.
///
/// The heuristic:
///
/// 1. On every `init()`, record **now** as the current launch
///    timestamp and clear the "graceful" flag.
/// 2. On `applicationWillTerminate`, set the flag to `true`.
/// 3. Next launch's `init()` sees: if the flag is `false` and
///    there's a previous-launch timestamp, *something* killed the
///    app without running `applicationWillTerminate`.
///
/// That alone produces false positives on normal Mac shutdown /
/// reboot (the system kills all user processes without draining
/// `NSApplication` lifecycle). To disambiguate, we also require a
/// crash report to exist under
/// `~/Library/Logs/DiagnosticReports/` with modification time
/// after the previous launch. Reboots produce no crash report, so
/// the banner only fires on actual abnormal exits.
///
/// Dismiss → the acknowledged previous-launch timestamp is stored
/// so the banner doesn't reappear until a **new** crash happens.
@MainActor
final class CrashBeacon: ObservableObject {

    @Published private(set) var crashedLastSession: Bool = false
    @Published private(set) var previousLaunchAt: Date?
    @Published private(set) var latestCrashReportURL: URL?

    private static let lastShutdownKey = "pulse.lastShutdown.graceful"
    private static let lastLaunchKey = "pulse.lastLaunch.timestamp"
    private static let crashAckKey = "pulse.crashAck.timestamp"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now

        let previousLaunchEpoch = defaults.double(forKey: Self.lastLaunchKey)
        let lastWasGraceful = defaults.bool(forKey: Self.lastShutdownKey)
        let ackEpoch = defaults.double(forKey: Self.crashAckKey)

        if previousLaunchEpoch > 0 {
            self.previousLaunchAt = Date(timeIntervalSince1970: previousLaunchEpoch)
        }

        if previousLaunchEpoch > 0,
           !lastWasGraceful,
           previousLaunchEpoch > ackEpoch,
           let crashURL = Self.mostRecentCrashReport(
               after: Date(timeIntervalSince1970: previousLaunchEpoch),
               using: fileManager
           ) {
            self.crashedLastSession = true
            self.latestCrashReportURL = crashURL
        }

        // Record this launch; clear graceful flag so the NEXT launch
        // sees a false if we're killed before `recordGracefulShutdown`.
        defaults.set(self.now().timeIntervalSince1970, forKey: Self.lastLaunchKey)
        defaults.set(false, forKey: Self.lastShutdownKey)
    }

    /// Wired into `AppDelegate.applicationWillTerminate(_:)`. A
    /// clean Cmd+Q, Sparkle-triggered restart, or system-initiated
    /// logout all fire this; kill -9, force-kill from Activity
    /// Monitor, and crashes do not.
    func recordGracefulShutdown() {
        defaults.set(true, forKey: Self.lastShutdownKey)
    }

    /// User clicked "Dismiss" on the banner. Stamp the ack so the
    /// banner doesn't reappear for the SAME crash; a future crash
    /// with a newer previousLaunchAt will surface again.
    func acknowledge() {
        guard let previousLaunchAt else { return }
        defaults.set(previousLaunchAt.timeIntervalSince1970, forKey: Self.crashAckKey)
        crashedLastSession = false
    }

    /// Reveal the most recent crash report in Finder. Falls back to
    /// opening the reports folder itself if one can't be pinpointed.
    func revealLatestCrashReport() {
        if let url = latestCrashReportURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let folder = Self.diagnosticReportsURL(using: fileManager)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Disk lookup

    private static func diagnosticReportsURL(using fm: FileManager) -> URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    /// Returns the newest `~/Library/Logs/DiagnosticReports/Pulse*`
    /// file whose modification time is after `cutoff`, or `nil`.
    /// The `Pulse` prefix covers both `PulseApp-…` (executable name
    /// from `scripts/package.sh`) and `Pulse-…` (should macOS ever
    /// key reports off the bundle display name). Works with both
    /// `.ips` (modern) and `.crash` (legacy) extensions.
    static func mostRecentCrashReport(after cutoff: Date, using fm: FileManager) -> URL? {
        let folder = diagnosticReportsURL(using: fm)
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let pulseFiles = contents.filter {
            let name = $0.lastPathComponent
            return (name.hasPrefix("Pulse") || name.hasPrefix("PulseApp"))
                && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
        }
        return pulseFiles
            .map { url -> (URL, Date) in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return (url, modified)
            }
            .filter { $0.1 > cutoff }
            .max(by: { $0.1 < $1.1 })?
            .0
    }
}
#endif

import Foundation
import PulseCore
import PulsePlatform

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Charts
import Combine

@main
struct PulseApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HealthMenuView(
                model: appDelegate.healthModel,
                onPause: { duration in appDelegate.pauseCollector(duration: duration) },
                onResume: { appDelegate.resumeCollector() },
                onShowBriefing: { appDelegate.requestShowBriefing() },
                onGenerateReport: { appDelegate.generateWeeklyReport() },
                onGenerateReportPDF: { appDelegate.generateWeeklyReportPDF() },
                onExportData: { appDelegate.exportData() },
                onCheckForUpdates: { appDelegate.updateController.checkForUpdates() }
            )
        } label: {
            // Use a different SF Symbol when collection is paused or
            // permissions are missing so the user can read state at a
            // glance from the menu bar. Wraps the raw Image so we can
            // host an invisible listener that opens the daily briefing
            // window when AppDelegate decides it's time (first wake of
            // the day, or the user asks explicitly via the menu).
            MenuBarLabel(
                model: appDelegate.healthModel,
                anomalyMonitor: appDelegate.anomalyMonitor,
                briefingTrigger: appDelegate.briefingTrigger,
                privacyAuditTrigger: appDelegate.privacyAuditTrigger,
                onboardingTrigger: appDelegate.onboardingTrigger
            )
        }
        .menuBarExtraStyle(.window)

        Window("Pulse Dashboard", id: "dashboard") {
            DashboardView(
                model: appDelegate.dashboardModel,
                healthModel: appDelegate.healthModel,
                crashBeacon: appDelegate.crashBeacon
            )
        }
        .defaultSize(width: 720, height: 480)

        Window("Yesterday in Pulse", id: "briefing") {
            DailyBriefingView(model: appDelegate.briefingModel)
        }
        .defaultSize(width: 420, height: 460)
        .windowResizability(.contentSize)

        Window("Privacy audit", id: "privacyAudit") {
            PrivacyAuditView(model: appDelegate.privacyAuditModel)
        }
        .defaultSize(width: 560, height: 520)

        Window("Welcome to Pulse", id: "onboarding") {
            OnboardingView(
                model: appDelegate.onboardingModel,
                onFinish: { appDelegate.finishOnboarding() }
            )
        }
        .defaultSize(width: 600, height: 540)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(
                goalsStore: appDelegate.goalsStore,
                onOpenPrivacyAudit: { appDelegate.requestShowPrivacyAudit() },
                onPurgeRange: { start, end in
                    try appDelegate.purgeRange(start: start, end: end)
                },
                onCheckForUpdates: { appDelegate.updateController.checkForUpdates() }
            )
        }
    }
}

/// Wrapper for the menu bar icon so it can host an invisible listener
/// that reacts to briefing triggers from `AppDelegate`. SwiftUI's
/// `@Environment(\.openWindow)` is only available inside views;
/// AppDelegate pings a `PassthroughSubject` and this view translates
/// the ping into the real window open.
struct MenuBarLabel: View {

    @ObservedObject var model: HealthModel
    @ObservedObject var anomalyMonitor: AnomalyMonitor
    let briefingTrigger: PassthroughSubject<Void, Never>
    let privacyAuditTrigger: PassthroughSubject<Void, Never>
    let onboardingTrigger: PassthroughSubject<Void, Never>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: model.menuBarIconName)
                // Let the icon actually *pulse* while the collector is
                // healthy — literalising the app name in the ambient
                // UI. Pauses / permission failures / silent-failure
                // states freeze the icon so the user notices something
                // is up without needing to read text.
                .pulseHeartbeat(
                    active: model.isLivelyCollecting,
                    amplitude: .menuBar
                )
            if anomalyMonitor.hasAnomaly {
                Circle()
                    .fill(PulseDesign.critical)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
                    .accessibilityLabel(Text("Anomaly", bundle: .pulse))
            }
        }
        .onReceive(briefingTrigger) { _ in
            openWindow(id: "briefing")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(privacyAuditTrigger) { _ in
            openWindow(id: "privacyAudit")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(onboardingTrigger) { _ in
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// AppDelegate owns the long-lived runtime objects: the database, the
/// collector actor, and the SwiftUI-observable health model. Construction
/// runs synchronously on the main actor; `applicationDidFinishLaunching`
/// kicks off the actual collection task.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let healthModel: HealthModel
    let dashboardModel: DashboardModel
    let briefingModel: DailyBriefingModel
    let privacyAuditModel: PrivacyAuditModel
    let onboardingModel: OnboardingModel
    let anomalyMonitor: AnomalyMonitor
    let goalsStore: GoalsStore
    let updateController: UpdateController
    let crashBeacon: CrashBeacon

    /// Passthrough channel the MenuBarLabel listens on to open the
    /// briefing window. AppDelegate fires this on first-wake-of-day and
    /// when the user explicitly picks "Yesterday's briefing" from the
    /// menu — both paths share the same "have we already shown today?"
    /// gate via UserDefaults.
    let briefingTrigger = PassthroughSubject<Void, Never>()

    /// Separate trigger for the privacy-audit window. Uses the same
    /// MenuBarLabel-listens-for-Void pattern so SettingsView can ask
    /// AppDelegate to open a window without itself holding a
    /// `@Environment(\.openWindow)` (Settings scenes run in a nested
    /// environment where that handle is unreliable).
    let privacyAuditTrigger = PassthroughSubject<Void, Never>()

    /// Trigger that asks the MenuBarLabel to open the onboarding window.
    /// Same invisible-listener pattern as briefing / privacy audit; fired
    /// once on `applicationDidFinishLaunching` for first-time users.
    let onboardingTrigger = PassthroughSubject<Void, Never>()

    private let database: PulseDatabase?
    private let runtime: CollectorRuntime?
    private let systemEventEmitter: SystemEventEmitter
    private let appWatcher: NSWorkspaceAppWatcher
    private let lidPowerObserver: LidPowerObserver
    private let titleObserver: AccessibilityTitleObserver
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        UserDefaults.registerPulseDefaults()

        let permissions = PulsePlatform.permissionService()
        let displayRegistry = PulsePlatform.displayRegistry()
        let dbResult = AppDelegate.openOrCreateDatabase()

        self.database = dbResult.database
        if let database = dbResult.database {
            let source = CGEventTapSource(
                permissions: permissions,
                displayRegistry: displayRegistry
            )
            self.runtime = CollectorRuntime(
                database: database,
                eventSource: source,
                permissions: permissions,
                displayRegistry: displayRegistry
            )
        } else {
            self.runtime = nil
        }

        self.systemEventEmitter = SystemEventEmitter()
        self.appWatcher = NSWorkspaceAppWatcher()
        self.lidPowerObserver = LidPowerObserver()
        self.titleObserver = AccessibilityTitleObserver()

        self.healthModel = HealthModel(
            permissionService: permissions,
            errorMessage: dbResult.errorMessage
        )
        self.goalsStore = GoalsStore()
        self.updateController = UpdateController()
        // Must be constructed once, **early**, during AppDelegate init:
        // its init records the launch timestamp and clears the
        // graceful-shutdown flag. Any later crash before
        // `applicationWillTerminate` runs will leave the flag at
        // false, which the next launch reads as "crashed".
        self.crashBeacon = CrashBeacon()
        self.dashboardModel = DashboardModel(
            store: dbResult.database.map { EventStore(database: $0) },
            goalsStore: self.goalsStore
        )
        self.briefingModel = DailyBriefingModel(
            store: dbResult.database.map { EventStore(database: $0) }
        )
        self.privacyAuditModel = PrivacyAuditModel(
            store: dbResult.database.map { EventStore(database: $0) }
        )
        self.anomalyMonitor = AnomalyMonitor(
            store: dbResult.database.map { EventStore(database: $0) }
        )
        self.onboardingModel = OnboardingModel(permissionService: permissions)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { [weak self] in await self?.bootCollector() }
        startHealthPolling()
        registerWakeObserver()
        anomalyMonitor.start()
        // Give the MenuBarLabel's PassthroughSubject listener a beat to
        // attach before we fire; otherwise the first-day trigger can miss.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard let self else { return }
                if !OnboardingModel.hasCompleted() {
                    // Brand-new install. Show onboarding before nudging
                    // any retention surfaces; the briefing / weekly
                    // report trigger off "first day" gates that wouldn't
                    // make sense on the very first launch anyway.
                    self.onboardingTrigger.send(())
                } else {
                    self.showBriefingIfDueToday()
                    self.generateWeeklyReportIfDue()
                }
            }
        }
    }

    /// Closes out the onboarding flow: marks the gate done (the model's
    /// "Open Pulse" button already did this, but a redundant write is
    /// safe) and dismisses the window. The user lands on a Mac with the
    /// menu bar icon live; from there one click opens the Dashboard,
    /// which is the spec from `docs/06-onboarding-permissions.md` §五.
    func finishOnboarding() {
        OnboardingModel.markCompleted()
        for window in NSApp.windows where window.identifier?.rawValue == "onboarding" {
            window.close()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        systemEventEmitter.stop()
        appWatcher.stop()
        lidPowerObserver.stop()
        titleObserver.stop()
        anomalyMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        // F-49b: stamp the graceful-shutdown flag. Reaching this
        // method means NSApplication got a clean terminate signal —
        // Cmd+Q, NSApplicationDelegate.applicationShouldTerminate
        // confirmation, Sparkle-initiated restart, or a user logout.
        // Kill -9 / SIGSEGV / force-quit bypasses this entirely, so
        // the next launch's CrashBeacon init detects the mismatch.
        crashBeacon.recordGracefulShutdown()
        Task { [runtime] in await runtime?.stop() }
    }

    // MARK: - User actions

    /// Pause the collector for the requested duration. Fire-and-forget;
    /// the HealthModel poll picks up the new pause state within 1s.
    func pauseCollector(duration: TimeInterval) {
        guard let runtime else { return }
        Task { await runtime.pause(reason: .userPause, duration: duration) }
    }

    /// Cancel any active pause immediately.
    func resumeCollector() {
        guard let runtime else { return }
        Task { await runtime.resume() }
    }

    /// Force-show the daily briefing window from a user action (menu bar).
    /// Skips the "already shown today" gate because the user explicitly
    /// asked — but still updates the gate so the automatic path doesn't
    /// re-show later the same day.
    func requestShowBriefing() {
        Self.markBriefingShownToday()
        Task { [weak self] in
            await self?.briefingModel.load(for: .yesterday)
            await MainActor.run { self?.briefingTrigger.send(()) }
        }
    }

    /// Loads the privacy-audit snapshot and asks the MenuBarLabel
    /// listener to open the window. Called from the Settings button.
    func requestShowPrivacyAudit() {
        Task { [weak self] in
            await self?.privacyAuditModel.reload()
            await MainActor.run { self?.privacyAuditTrigger.send(()) }
        }
    }

    /// F-47 — user-initiated purge of every data row whose timestamp
    /// falls in `[start, end)`. Runs on a background queue; throws
    /// back to the caller if the database is unavailable or the
    /// write transaction fails so the Settings sheet can surface
    /// the error instead of silently lying about "done".
    func purgeRange(start: Date, end: Date) throws -> RangePurgeResult {
        guard let database else {
            throw PurgeError.databaseUnavailable
        }
        let store = EventStore(database: database)
        return try store.purgeRange(start: start, end: end)
    }

    enum PurgeError: LocalizedError {
        case databaseUnavailable

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable:
                return String(
                    localized: "Database is not available — permission or storage issue.",
                    bundle: .pulse,
                    comment: "F-47 error — no database to purge against."
                )
            }
        }
    }

    /// Exports the last 30 days + today as a JSON document the user can
    /// pipe into their own tooling (Obsidian, spreadsheets, personal
    /// scripts). Opens Finder at the resulting file.
    func exportData() {
        guard let database else { return }
        let store = EventStore(database: database)
        Task.detached {
            do {
                let bundle = try store.buildExportBundle()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(bundle)
                let url = try Self.writeExportToDisk(data: data, endingAt: Date())
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                #if DEBUG
                print("export failed: \(error)")
                #endif
            }
        }
    }

    private nonisolated static func writeExportToDisk(data: Data, endingAt: Date) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: endingAt)
        let stamp = String(format: "%04d-%02d-%02d",
                           comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        let url = dir.appendingPathComponent("pulse-export-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// User-initiated weekly report generation. Writes an HTML file to
    /// `~/Library/Application Support/Pulse/reports/` and opens it in
    /// the default browser. Fails silently on I/O errors; a future slice
    /// can surface them through HealthModel.errorMessage.
    func generateWeeklyReport() {
        guard let database else { return }
        let store = EventStore(database: database)
        Task.detached {
            do {
                let report = try store.weeklyReport(endingAt: Date())
                let html = WeeklyReportRenderer.renderLocalized(report: report)
                let url = try WeeklyReportRenderer.writeToDisk(html: html, endingAt: Date())
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            } catch {
                #if DEBUG
                print("weekly report failed: \(error)")
                #endif
            }
        }
    }

    /// F-06 — same weekly report as `generateWeeklyReport()` but
    /// rendered through `WKWebView.pdf(...)` into a PDF file. The
    /// HTML pipeline is reused as-is; PDF is strictly a presentation
    /// layer on top. Reveals the resulting file in Finder on success.
    ///
    /// `WKWebView` is main-actor-bound and `makePDF` suspends while
    /// WebKit completes its load, so the outer `Task` inherits
    /// AppDelegate's `@MainActor` isolation rather than running on a
    /// detached executor. The DB read (`weeklyReport`) is a small
    /// handful of rows — cheap enough on main.
    func generateWeeklyReportPDF() {
        guard let database else { return }
        let store = EventStore(database: database)
        let endingAt = Date()
        Task {
            do {
                let report = try store.weeklyReport(endingAt: endingAt)
                let html = WeeklyReportRenderer.renderLocalized(report: report)
                let pdfData = try await WeeklyReportPDFRenderer.makePDF(html: html)
                let url = try WeeklyReportPDFRenderer.writeToDisk(
                    pdfData: pdfData,
                    endingAt: endingAt
                )
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                #if DEBUG
                print("weekly PDF report failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Daily briefing gate

    private static let briefingGateKey = "pulse.briefing.lastShownDay"

    private static func todayKey(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func markBriefingShownToday() {
        UserDefaults.standard.set(todayKey(), forKey: briefingGateKey)
    }

    private func showBriefingIfDueToday() {
        let today = Self.todayKey()
        let lastShown = UserDefaults.standard.string(forKey: Self.briefingGateKey)
        guard lastShown != today else { return }
        Self.markBriefingShownToday()
        Task { [weak self] in
            await self?.briefingModel.load(for: .yesterday)
            await MainActor.run { self?.briefingTrigger.send(()) }
        }
    }

    private func registerWakeObserver() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showBriefingIfDueToday()
                self?.generateWeeklyReportIfDue()
            }
        }
    }

    // MARK: - Weekly report auto-trigger

    private static let reportWeekKey = "pulse.report.lastGeneratedISOWeek"

    /// ISO-week key ("2026-W16") used to detect "a new week has started
    /// since we last generated". ISO weeks start on Monday, so dropping
    /// the report on Monday morning is a natural side effect.
    private static func currentISOWeekKey(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return String(format: "%04d-W%02d",
                      comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }

    private func generateWeeklyReportIfDue() {
        let currentKey = Self.currentISOWeekKey()
        let lastKey = UserDefaults.standard.string(forKey: Self.reportWeekKey)
        guard lastKey != currentKey else { return }
        UserDefaults.standard.set(currentKey, forKey: Self.reportWeekKey)
        generateWeeklyReport()
    }

    // MARK: - Private

    private func bootCollector() async {
        guard let runtime else { return }
        do {
            try await runtime.start()
        } catch {
            await MainActor.run { healthModel.recordStartupError(error) }
            return
        }
        // Start auxiliary sources and pipe them into the runtime.
        let feed: @Sendable (DomainEvent) -> Void = { event in
            Task.detached {
                await runtime.ingestExternalEvent(event)
            }
        }
        systemEventEmitter.start(handler: feed)
        appWatcher.start(handler: feed)
        lidPowerObserver.start(handler: feed)
        titleObserver.start(handler: feed)
    }

    private func startHealthPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if let runtime = self.runtime {
                    let snapshot = await runtime.healthSnapshot()
                    await MainActor.run { self.healthModel.update(snapshot) }
                } else {
                    await MainActor.run { self.healthModel.refreshPermissionsOnly() }
                }
            }
        }
    }

    private static func openOrCreateDatabase() -> (database: PulseDatabase?, errorMessage: String?) {
        do {
            let url = try AppDelegate.databaseURL()
            let database = try PulseDatabase.open(at: url)
            return (database, nil)
        } catch {
            return (nil, "Failed to open database: \(error.localizedDescription)")
        }
    }

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Pulse", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("pulse.db")
    }
}

/// Observable data exposed to SwiftUI. Updated on the main actor; views
/// observe the published `snapshot` and `errorMessage`.
@MainActor
final class HealthModel: ObservableObject {

    @Published private(set) var snapshot: HealthSnapshot
    @Published private(set) var errorMessage: String?

    private let permissionService: PermissionService

    init(permissionService: PermissionService, errorMessage: String? = nil) {
        self.permissionService = permissionService
        self.errorMessage = errorMessage
        self.snapshot = HealthModel.bootstrapSnapshot(
            permissions: permissionService.snapshot(at: Date())
        )
    }

    func update(_ snapshot: HealthSnapshot) {
        self.snapshot = snapshot
    }

    func refreshPermissionsOnly() {
        let permissions = permissionService.snapshot(at: Date())
        self.snapshot = HealthSnapshot(
            capturedAt: Date(),
            isRunning: false,
            pause: snapshot.pause,
            permissions: permissions,
            writer: snapshot.writer,
            rollupStamps: snapshot.rollupStamps,
            l0Counts: snapshot.l0Counts,
            databaseFileSizeBytes: snapshot.databaseFileSizeBytes,
            lastWriteAt: snapshot.lastWriteAt
        )
    }

    func recordStartupError(_ error: Error) {
        self.errorMessage = String.localizedStringWithFormat(
            NSLocalizedString("Couldn't start the collector: %@", bundle: .pulse, comment: ""),
            error.localizedDescription
        )
    }

    var menuBarIconName: String {
        if errorMessage != nil { return "exclamationmark.triangle" }
        if !snapshot.permissions.isAllRequiredGranted { return "exclamationmark.triangle" }
        if snapshot.pause.isActive { return "pause.circle" }
        if snapshot.isSilentlyFailing { return "exclamationmark.circle" }
        return "waveform.path.ecg"
    }

    /// `true` when the collector is in a healthy steady state and the
    /// menu-bar icon should breathe. Any abnormal state (missing
    /// permissions / paused / silently failing / error) returns
    /// `false` so the icon freezes — a one-glance "something is off"
    /// signal that doesn't need to be read as text.
    var isLivelyCollecting: Bool {
        errorMessage == nil
            && snapshot.permissions.isAllRequiredGranted
            && !snapshot.pause.isActive
            && !snapshot.isSilentlyFailing
    }

    private static func bootstrapSnapshot(permissions: PermissionSnapshot) -> HealthSnapshot {
        HealthSnapshot(
            capturedAt: Date(),
            isRunning: false,
            pause: PauseController.State(isActive: false, reason: nil, resumesAt: nil),
            permissions: permissions,
            writer: .empty,
            rollupStamps: .empty,
            l0Counts: L0Counts(mouseMoves: 0, mouseClicks: 0, keyEvents: 0),
            databaseFileSizeBytes: nil,
            lastWriteAt: nil
        )
    }
}

// MARK: - Dashboard model

/// Owns the read-side query state for the Dashboard window. Refreshes on a
/// 5-second cadence whenever the window is open. The model holds the
/// `EventStore` directly (rather than going through the runtime actor)
/// because reads are cheap, lock-protected by GRDB, and don't need any of
/// the runtime's gating.
@MainActor
final class DashboardModel: ObservableObject {

    @Published private(set) var summary: TodaySummary?
    @Published private(set) var heatmapCells: [HeatmapCell] = []
    @Published private(set) var heatmapDays: Int = DashboardModel.defaultHeatmapDays
    @Published private(set) var trendPoints: [DailyTrendPoint] = []
    @Published private(set) var longestFocus: FocusSegment?
    @Published private(set) var sessionPosture: SessionPosture = .empty
    @Published private(set) var goalProgress: [GoalProgress] = []
    @Published private(set) var insights: [Insight] = []
    @Published private(set) var continuity: ContinuityStreak?
    @Published private(set) var lidOpensToday: Int = 0
    @Published private(set) var lidOpensTrend: [Int] = []
    @Published private(set) var restToday: RestDay = RestDay(segments: [])
    @Published private(set) var timelineToday: DayTimeline?
    /// F-33 — top shortcuts used today, sorted by count desc.
    @Published private(set) var shortcutsToday: [ShortcutUsageRow] = []
    /// F-09 — today's time-in-category breakdown for the focus donut.
    @Published private(set) var focusDonut: FocusDonut = .empty
    /// F-08 — 7-day keycode distribution for the keyboard heatmap.
    /// Empty until the user opts into D-K2 capture.
    @Published private(set) var keyCodeDistribution: [KeyCodeCount] = []
    /// F-22 — today's passive consumption summary (foreground + idle
    /// + screen-on time attributed by bundle). `.empty` until the day
    /// has at least one qualifying window.
    @Published private(set) var passiveToday: PassiveConsumption = .empty
    /// F-12 — today's peak typing minute, or `nil` before the user has
    /// logged any keystrokes for the day. Surfaces the busiest minute
    /// as a KPM headline on the Dashboard's Focus section.
    @Published private(set) var keyPressPeak: KeyPressPeakMinute?
    /// F-43 — this-week-vs-last-week deltas across the four daily-trend
    /// metrics. `nil` on a fresh install until enough days have rolled
    /// into `hour_summary` for both halves to have data.
    @Published private(set) var weekOverWeek: PeriodComparison?
    /// F-04 — per-display 128×128 density histograms over
    /// `trajectoryDays`. The Card asks a renderer for a `CGImage` off
    /// the main thread via `.task(id:)`, so this struct stays cheap to
    /// publish even when it carries several thousand non-zero cells.
    @Published private(set) var trajectoryTiles: [MouseTrajectoryTileData] = []
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentAchievement: LandmarkAchievement?
    /// F-25 — lifetime-scale celebration. Fires at most once per
    /// landmark per user (persistence is not day-keyed), so the
    /// banner doesn't replay every day the user crosses "marathon"
    /// again today. Larger landmarks like "Pacific" or "equator"
    /// effectively become rare, earned events.
    @Published private(set) var recentLifetimeAchievement: LandmarkAchievement?

    private let store: EventStore?
    private let goalsStore: GoalsStore
    private let insightEngine = InsightEngine()
    private var refreshTask: Task<Void, Never>?

    /// Default heatmap window (in days). The user can override via the
    /// Settings panel; the `refresh()` loop re-reads the preference on
    /// every tick so changes take effect on the next poll.
    ///
    /// `nonisolated` because `UserDefaults.registerPulseDefaults()` runs
    /// outside the main actor during `AppDelegate.init` — we just need
    /// the constant, not any instance state.
    nonisolated static let defaultHeatmapDays = 7
    /// Weekly trend chart span — fixed at 7 days for MVP; not user-tunable.
    nonisolated static let trendDays = 7
    /// F-43 week-over-week window. Always 14: 7 days "this week" vs
    /// 7 days "last week". The card builder falls back to an even
    /// split if a partial fetch returns fewer rows.
    nonisolated static let weekOverWeekDays = 14
    /// F-11 continuity grid window. 52 × 7 = 364 days, plus one cell so
    /// the newest column is always "this week" regardless of which
    /// weekday today is.
    nonisolated static let continuityDays = 365
    /// F-04 trajectory-density window. 7 days covers "my last week" —
    /// the obvious zoom for a density map — and keeps the query under
    /// ~20k rows even on a two-display setup.
    nonisolated static let trajectoryDays = 7

    init(store: EventStore?, goalsStore: GoalsStore) {
        self.store = store
        self.goalsStore = goalsStore
        self.alertsController = ThresholdAlertsController()
    }

    private let alertsController: ThresholdAlertsController

    /// Begin polling. Idempotent — calling twice is a no-op. Cadence is
    /// read from `UserDefaults` on every iteration so changes in the
    /// Settings panel take effect without restarting the window.
    func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let raw = UserDefaults.standard.double(
                    forKey: PulsePreferenceKey.dashboardRefreshIntervalSeconds
                )
                let seconds = max(1.0, raw > 0 ? raw : Self.defaultRefreshIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Default refresh cadence used when the user hasn't overridden it
    /// via the Settings panel. Exposed so `UserDefaults.registerDefaults`
    /// can seed the same value (see the `nonisolated` note above).
    nonisolated static let defaultRefreshIntervalSeconds: Double = 5.0

    /// Reads the heatmap-days preference and clamps to the allowed range.
    /// Centralised so the polling loop and the Settings picker can't drift.
    static func resolvedHeatmapDays() -> Int {
        let raw = UserDefaults.standard.integer(forKey: PulsePreferenceKey.heatmapDays)
        let value = raw > 0 ? raw : defaultHeatmapDays
        return min(30, max(3, value))
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard let store else {
            errorMessage = String(localized: "Database not available.", bundle: .pulse)
            return
        }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let days = Self.resolvedHeatmapDays()
        do {
            let summary = try store.todaySummary(start: dayStart, end: dayEnd, capUntil: now)
            let heatmap = try store.hourlyHeatmap(endingAt: now, days: days)
            let trend = try store.dailyTrend(endingAt: now, days: Self.trendDays)
            let comparisonTrend = try store.dailyTrend(
                endingAt: now,
                days: Self.weekOverWeekDays
            )
            let weekOverWeek = PeriodComparisonBuilder.split(from: comparisonTrend)
            let focus = try store.longestFocusSegment(on: dayStart, now: now)
            let posture = try store.sessionPosture(on: dayStart, now: now)
            let switches = try store.appSwitchCount(on: dayStart, capUntil: now)
            let continuity = try store.continuityStreak(endingAt: now, days: Self.continuityDays)
            let lidToday = try store.dailyLidOpens(on: dayStart, capUntil: now)
            let lidTrend = try store.lidOpensTrend(endingAt: now, days: Self.trendDays)
            let restDay = try store.restSegments(on: dayStart, capUntil: now)
            let timeline = try store.dayTimeline(on: dayStart, capUntil: now)
            let keyPeak = try store.peakKeyPressMinute(start: dayStart, capUntil: now)
            let passive = try store.passiveConsumption(on: dayStart, capUntil: now)
            let shortcuts = try store.shortcutLeaderboard(start: dayStart, end: dayEnd, limit: 5)
            let keyCodes = try store.keyCodeDistribution(endingAt: now, days: 7)
            // F-09 — ask for up to 200 bundles so the "other" slice is
            // accurate. In practice a day's distinct-bundle count is
            // well under 50, so 200 is pure headroom.
            let allAppsToday = try store.appUsageRanking(
                start: dayStart,
                end: dayEnd,
                capUntil: now,
                limit: 200
            )
            let focusDonut = FocusDonutBuilder.build(from: allAppsToday)
            // F-04 — `mouseDensity` reads from the pre-binned
            // `day_mouse_density` table (B9) so this is a lightweight
            // grouped scan even over 7 days. `latestDisplaySnapshot`
            // is one extra PK-lookup per display — fine inside the
            // refresh loop.
            let trajectoryHistograms = try store.mouseDensity(
                endingAt: now,
                days: Self.trajectoryDays
            )
            var trajectoryTiles: [MouseTrajectoryTileData] = []
            trajectoryTiles.reserveCapacity(trajectoryHistograms.count)
            for histogram in trajectoryHistograms {
                let snapshot = try? store.latestDisplaySnapshot(displayId: histogram.displayId)
                trajectoryTiles.append(
                    MouseTrajectoryTileData(
                        histogram: histogram,
                        snapshot: snapshot
                    )
                )
            }
            let progress = GoalEvaluator.evaluate(
                goals: goalsStore.enabledGoals(),
                summary: summary,
                longestFocus: focus,
                appSwitchesToday: switches
            )
            // A27 — run the cross-metric rule engine. The past-days
            // longest-focus query is one extra DB hit per prior day;
            // `try?` so a single-day failure just reduces the history
            // the deep-focus rule sees rather than blanking the whole
            // insights row.
            let calendar = Calendar.current
            let pastLongestFocus: [Int] = (1...(Self.trendDays - 1)).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: dayStart),
                      let segment = try? store.longestFocusSegment(on: day, now: now)
                else {
                    return nil
                }
                return segment.durationSeconds
            }
            let insightContext = InsightContext(
                today: summary,
                pastDailyTrend: Array(trend.dropLast()),
                todayLongestFocus: focus,
                pastLongestFocusSeconds: pastLongestFocus,
                heatmapCells: heatmap,
                continuity: continuity,
                now: now,
                calendar: calendar
            )
            self.summary = summary
            self.heatmapCells = heatmap
            self.heatmapDays = days
            self.trendPoints = trend
            self.longestFocus = focus
            self.sessionPosture = posture
            self.goalProgress = progress
            self.insights = insightEngine.evaluate(context: insightContext)
            self.continuity = continuity
            self.lidOpensToday = lidToday
            self.lidOpensTrend = lidTrend
            self.restToday = restDay
            self.timelineToday = timeline
            self.keyPressPeak = keyPeak
            self.passiveToday = passive
            self.shortcutsToday = shortcuts
            self.keyCodeDistribution = keyCodes
            self.focusDonut = focusDonut
            self.weekOverWeek = weekOverWeek
            self.trajectoryTiles = trajectoryTiles
            self.lastRefreshAt = now
            self.errorMessage = nil
            updateAchievementIfNeeded(
                distanceMillimeters: summary.totalMouseDistanceMillimeters,
                now: now
            )
            let lifetimeMm = (try? store.lifetimeMouseDistanceMillimeters()) ?? 0
            updateLifetimeAchievementIfNeeded(
                lifetimeMillimeters: lifetimeMm,
                now: now
            )
            // F-45 — threshold alerts. Derive "continuous active" from
            // today's rest segments + dayStart; evaluator is pure so
            // the controller just delivers the output.
            let continuousActive = ContinuousActiveDeriver.derive(
                restSegments: restDay.segments.map {
                    (startedAt: $0.startedAt, endedAt: $0.endedAt)
                },
                dayStart: dayStart,
                now: now
            )
            alertsController.evaluateAndFire(
                metrics: ThresholdAlertMetrics(
                    activeSecondsToday: summary.totalActiveSeconds,
                    continuousActiveSeconds: continuousActive
                ),
                now: now
            )
        } catch {
            self.errorMessage = String.localizedStringWithFormat(
                NSLocalizedString("Failed to load summary: %@", bundle: .pulse, comment: ""),
                error.localizedDescription
            )
        }
    }

    // MARK: - Milestone achievements (F-25)

    /// Day-keyed storage of the highest landmark index the user has
    /// acknowledged today. Comparing `currentIndex > storedIndex` is what
    /// drives the one-shot achievement banner.
    private static let achievementDayKey = "pulse.achievement.day"
    private static let achievementLandmarkIndexKey = "pulse.achievement.landmarkIndex"

    private func updateAchievementIfNeeded(distanceMillimeters: Double, now: Date) {
        let meters = distanceMillimeters / 1_000.0
        let dayKey = Self.achievementDayString(for: now)
        let storedDay = UserDefaults.standard.string(forKey: Self.achievementDayKey)
        var storedIndex: Int
        if storedDay != dayKey {
            UserDefaults.standard.set(dayKey, forKey: Self.achievementDayKey)
            UserDefaults.standard.set(-1, forKey: Self.achievementLandmarkIndexKey)
            storedIndex = -1
            // New day — clear any stale achievement from yesterday.
            recentAchievement = nil
        } else if UserDefaults.standard.object(forKey: Self.achievementLandmarkIndexKey) == nil {
            storedIndex = -1
        } else {
            storedIndex = UserDefaults.standard.integer(forKey: Self.achievementLandmarkIndexKey)
        }

        let landmarks = LandmarkLibrary.standard.landmarks
        let currentIndex = landmarks.lastIndex(where: { $0.distanceMeters <= meters }) ?? -1
        guard currentIndex > storedIndex, currentIndex >= 0 else { return }
        let landmark = landmarks[currentIndex]
        recentAchievement = LandmarkAchievement(
            landmark: landmark,
            metersReached: meters,
            firstReachedAt: now
        )
    }

    // MARK: - Lifetime milestones (F-25)

    /// Not day-keyed — a lifetime landmark fires once per user.
    private static let lifetimeLandmarkIndexKey = "pulse.achievement.lifetimeLandmarkIndex"

    private func updateLifetimeAchievementIfNeeded(lifetimeMillimeters: Double, now: Date) {
        let meters = lifetimeMillimeters / 1_000.0
        let storedIndex: Int
        if UserDefaults.standard.object(forKey: Self.lifetimeLandmarkIndexKey) == nil {
            storedIndex = -1
        } else {
            storedIndex = UserDefaults.standard.integer(forKey: Self.lifetimeLandmarkIndexKey)
        }
        let landmarks = LandmarkLibrary.standard.landmarks
        let currentIndex = landmarks.lastIndex(where: { $0.distanceMeters <= meters }) ?? -1
        guard currentIndex > storedIndex, currentIndex >= 0 else { return }
        let landmark = landmarks[currentIndex]
        recentLifetimeAchievement = LandmarkAchievement(
            landmark: landmark,
            metersReached: meters,
            firstReachedAt: now
        )
    }

    /// Acknowledge the lifetime-tier banner. The stored index moves up
    /// to the dismissed landmark so only higher ones will ever fire
    /// the lifetime banner again.
    func dismissLifetimeAchievement() {
        guard let achievement = recentLifetimeAchievement else { return }
        let landmarks = LandmarkLibrary.standard.landmarks
        if let idx = landmarks.firstIndex(where: { $0.key == achievement.landmark.key }) {
            UserDefaults.standard.set(idx, forKey: Self.lifetimeLandmarkIndexKey)
        }
        recentLifetimeAchievement = nil
    }

    /// Acknowledge the current achievement so it doesn't re-appear on the
    /// next refresh tick. Moves the stored index up to include the
    /// landmark the banner showed; subsequent (higher) landmarks still
    /// trigger their own banner.
    func dismissAchievement() {
        guard let achievement = recentAchievement else { return }
        let landmarks = LandmarkLibrary.standard.landmarks
        if let idx = landmarks.firstIndex(where: { $0.key == achievement.landmark.key }) {
            UserDefaults.standard.set(idx, forKey: Self.achievementLandmarkIndexKey)
        }
        recentAchievement = nil
    }

    private static func achievementDayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

/// One-shot achievement payload for the Dashboard's milestone banner.
/// `metersReached` is the raw distance at the time the landmark was
/// crossed so the banner shows the actual headline number, not the
/// landmark's canonical distance.
struct LandmarkAchievement: Equatable {
    let landmark: Landmark
    let metersReached: Double
    let firstReachedAt: Date
}

// MARK: - Localization helpers

/// Translated display name for a `Permission`. `PulseCore` keeps the
/// canonical `Permission.displayName` in English so tests and logs stay
/// stable; the View layer maps the enum to the matching catalog key.
func localizedPermissionStatus(_ status: PermissionStatus) -> String {
    let key: String
    switch status {
    case .granted:        key = "permission.status.granted"
    case .denied:         key = "permission.status.denied"
    case .notDetermined:  key = "permission.status.notDetermined"
    case .unknown:        key = "permission.status.unknown"
    }
    return NSLocalizedString(key, bundle: .pulse, value: status.rawValue, comment: "")
}

func localizedPermissionName(_ permission: Permission) -> String {
    let key: String
    switch permission {
    case .inputMonitoring: key = "Input Monitoring"
    case .accessibility:   key = "Accessibility"
    case .calendars:       key = "Calendars"
    case .location:        key = "Location Services"
    case .notifications:   key = "Notifications"
    }
    return NSLocalizedString(key, bundle: .pulse, value: permission.displayName, comment: "")
}

// MARK: - Views

struct HealthMenuView: View {

    @ObservedObject var model: HealthModel
    let onPause: (TimeInterval) -> Void
    let onResume: () -> Void
    let onShowBriefing: () -> Void
    let onGenerateReport: () -> Void
    let onGenerateReportPDF: () -> Void
    let onExportData: () -> Void
    let onCheckForUpdates: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pulse", bundle: .pulse)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                // Gearshape right next to the app name — the only
                // Settings entry on a menu-bar-only (LSUIElement=1)
                // build, because `⌘,` needs a key window Pulse never
                // has by default and the system menu-bar is suppressed.
                Button {
                    openSettings()
                    // `.accessory` activation policy keeps Pulse out of
                    // the Dock; activate the process explicitly so the
                    // Settings window comes to front instead of dropping
                    // behind whatever was previously focused.
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Settings…", bundle: .pulse))
                .accessibilityLabel(Text("Settings…", bundle: .pulse))
                Spacer()
                Text(localizedStatusHeadline(for: model.snapshot), bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Divider().overlay(PulseDesign.warmGray(0.14))

            CountersView(snapshot: model.snapshot)

            Divider().overlay(PulseDesign.warmGray(0.14))

            PauseControlsView(
                pause: model.snapshot.pause,
                capturedAt: model.snapshot.capturedAt,
                onPause: onPause,
                onResume: onResume
            )

            Divider().overlay(PulseDesign.warmGray(0.14))

            PermissionList(snapshot: model.snapshot.permissions)

            PermissionAssistantView(snapshot: model.snapshot.permissions)

            if let message = model.errorMessage {
                Divider().overlay(PulseDesign.warmGray(0.14))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(PulseDesign.critical)
            }

            Divider().overlay(PulseDesign.warmGray(0.14))

            VStack(spacing: 10) {
                // Both CTAs share the same hand-drawn chip so they're
                // exactly symmetrical in size and shape — only the fill
                // color distinguishes primary (coral) from secondary
                // (warmGray). Using `.buttonStyle(.borderedProminent)` /
                // `.bordered` on macOS lets AppKit clamp the label color
                // to its control tint, which broke dark-mode contrast
                // and also made the two buttons visibly non-symmetrical.
                HStack {
                    Button {
                        openWindow(id: "dashboard")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Open Dashboard", bundle: .pulse)
                            .menuBarChip(fill: PulseDesign.coral, foreground: .white)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { NSApp.terminate(nil) } label: {
                        Text("Quit Pulse", bundle: .pulse)
                            .menuBarChip(fill: PulseDesign.warmGray(0.18))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q")
                }
                // Evenly distribute the secondary actions across the
                // full row — first/last button sit flush with the main
                // CTA edges above, matching their visual column. A
                // trailing `Spacer()` left them clumped on the left,
                // which read as an alignment bug against the wide
                // row above.
                HStack(spacing: 0) {
                    Button(action: onShowBriefing) {
                        Text("Yesterday's briefing", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: onGenerateReport) {
                        Text("Generate weekly report", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: onGenerateReportPDF) {
                        Text("Weekly PDF…", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: onExportData) {
                        Text("Export data…", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: onCheckForUpdates) {
                        Text("Check for updates…", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Derives the menu-bar status headline from the raw HealthSnapshot
    /// flags so it can be localized via the xcstrings catalog. Mirrors
    /// `HealthSnapshot.statusHeadline` (which remains English-only for
    /// developer logs).
    private func localizedStatusHeadline(for snapshot: HealthSnapshot) -> LocalizedStringKey {
        if snapshot.pause.isActive {
            switch snapshot.pause.reason {
            case .userPause:       return "Paused — collection resumes shortly."
            case .sensitivePeriod: return "Sensitive period active."
            case .none:            return "Paused."
            }
        }
        if !snapshot.permissions.isAllRequiredGranted {
            return "Waiting for permissions."
        }
        if snapshot.isSilentlyFailing {
            return "Collector idle — please open settings."
        }
        if snapshot.isRunning {
            return "Listening to your pulse."
        }
        return "Stopped."
    }
}

private extension View {
    /// Shared chip styling for the two menu-bar CTAs so they're strictly
    /// symmetrical — same font, padding, corner radius and height. Only
    /// the fill color distinguishes primary (coral) from secondary
    /// (warmGray). Kept as a View extension rather than a custom
    /// ButtonStyle because AppKit-backed styles clamp the label color
    /// to the control tint, which was how the two prior attempts at
    /// dark-mode contrast kept regressing.
    func menuBarChip(fill: Color, foreground: Color = .primary) -> some View {
        self
            .font(.body)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
    }
}

/// Two states: paused (shows a countdown + Resume button) or idle
/// (shows a 3-way Pause menu: 15m / 30m / 1h). Pauses of different
/// lengths compose via `PauseController`, which takes the later of
/// the current and requested deadlines.
struct PauseControlsView: View {

    let pause: PauseController.State
    let capturedAt: Date
    let onPause: (TimeInterval) -> Void
    let onResume: () -> Void

    var body: some View {
        if pause.isActive, let resumesAt = pause.resumesAt {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text("Paused", bundle: .pulse)
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(PulseDesign.amber)
                    Text("Resumes \(PulseFormat.countdown(from: capturedAt, to: resumesAt))", bundle: .pulse)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onResume) {
                    Text("Resume now", bundle: .pulse)
                }
            }
        } else {
            Menu {
                Button { onPause(15 * 60) } label: { Text("15 minutes", bundle: .pulse) }
                Button { onPause(30 * 60) } label: { Text("30 minutes", bundle: .pulse) }
                Button { onPause(60 * 60) } label: { Text("1 hour",     bundle: .pulse) }
            } label: {
                Label {
                    Text("Pause collection…", bundle: .pulse)
                } icon: {
                    Image(systemName: "pause.circle")
                }
                .font(.footnote)
            }
            .menuStyle(.borderlessButton)
        }
    }
}

struct DashboardView: View {

    @ObservedObject var model: DashboardModel
    @ObservedObject var healthModel: HealthModel
    @ObservedObject var crashBeacon: CrashBeacon

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseDesign.cardSpacing) {
                header
                DashboardPermissionBanner(permissions: healthModel.snapshot.permissions)
                if crashBeacon.crashedLastSession {
                    CrashBeaconBanner(beacon: crashBeacon)
                }
                if let lifetime = model.recentLifetimeAchievement {
                    LifetimeMilestoneBanner(
                        achievement: lifetime,
                        onDismiss: { model.dismissLifetimeAchievement() }
                    )
                }
                if let achievement = model.recentAchievement {
                    MilestoneAchievementBanner(
                        achievement: achievement,
                        onDismiss: { model.dismissAchievement() }
                    )
                }
                if let summary = model.summary {
                    // ── Section 1 — Today's pulse (above the fold) ──
                    // Goals first when intent is set, then the hero
                    // mileage on the left + 6 summary tiles on the
                    // right. Together this is the "30-second glance".
                    if !model.goalProgress.isEmpty {
                        GoalsCard(progress: model.goalProgress)
                    }
                    todayPulseSection(summary: summary)

                    // ── Section 1b — Insights (A27) ──
                    // Rendered inline only when a rule actually fired;
                    // an "everything is normal" tile would add noise
                    // for no payoff.
                    if !model.insights.isEmpty {
                        InsightsCard(insights: model.insights)
                    }

                    // ── Section 2 — Rhythm (trends across the week) ──
                    DashboardSectionHeader(titleKey: "Rhythm")
                    WeekTrendChart(points: model.trendPoints)
                    WeekHourlyHeatmap(cells: model.heatmapCells, days: model.heatmapDays)
                    if let comparison = model.weekOverWeek {
                        WeekOverWeekCard(comparison: comparison)
                    }
                    ContinuityCard(streak: model.continuity)
                    if model.lidOpensTrend.contains(where: { $0 > 0 }) {
                        LidCard(
                            todayOpens: model.lidOpensToday,
                            trend: model.lidOpensTrend
                        )
                    }

                    // ── Section 3 — Focus (depth + sessions) ──
                    DashboardSectionHeader(titleKey: "Focus")
                    HStack(alignment: .top, spacing: PulseDesign.cardSpacing) {
                        DeepFocusCard(segment: model.longestFocus)
                            .frame(maxWidth: .infinity)
                        UsagePostureCard(posture: model.sessionPosture)
                            .frame(maxWidth: .infinity)
                    }
                    if model.focusDonut.totalSeconds > 0 {
                        FocusDonutCard(donut: model.focusDonut)
                    }
                    KeyboardPeakCard(peak: model.keyPressPeak)
                    RestCard(rest: model.restToday)
                    if model.passiveToday.totalSeconds > 0 {
                        PassiveConsumptionCard(passive: model.passiveToday)
                    }

                    // ── Section 4 — Apps ──
                    DashboardSectionHeader(titleKey: "Apps")
                    DayTimelineCard(timeline: model.timelineToday)
                    AppRankingChart(rows: summary.topApps)
                    if !model.shortcutsToday.isEmpty {
                        ShortcutLeaderboardCard(rows: model.shortcutsToday)
                    }
                    KeyboardHeatmapCard(keyCodes: model.keyCodeDistribution)
                    if !model.trajectoryTiles.isEmpty {
                        MouseTrajectoryCard(tiles: model.trajectoryTiles)
                    }

                    // ── Section 5 — Health (diagnostics, kept last) ──
                    DashboardSectionHeader(titleKey: "Health")
                    DiagnosticsCard(snapshot: healthModel.snapshot)
                } else if model.errorMessage != nil {
                    Text(model.errorMessage ?? "")
                        .foregroundStyle(PulseDesign.critical)
                } else {
                    ProgressView {
                        Text("Loading today's data…", bundle: .pulse)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                }
            }
            .padding(28)
        }
        .background(PulseDesign.surface)
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Refresh immediately on app activation instead of waiting for
            // the next 5-second poll tick. The 5s cadence is fine while the
            // user is actively looking at the window; the lag is what
            // irritates when they switch back from another app.
            Task { await model.refresh() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label {
                        Text("Refresh", bundle: .pulse)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today", bundle: .pulse)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            if let last = model.lastRefreshAt {
                Text("Updated \(PulseFormat.ago(from: last, to: Date()))", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// First section of the dashboard — the "30-second glance" the user
    /// sees without scrolling. Mileage hero + landmark progress on the
    /// left (the dramatic story); 6 summary tiles on the right (the
    /// raw counters). At min window width (820pt) the two columns each
    /// get ~390pt, comfortably fitting a 2-column tile grid on the right.
    @ViewBuilder
    private func todayPulseSection(summary: TodaySummary) -> some View {
        DashboardSectionHeader(titleKey: "Today's pulse")
        HStack(alignment: .top, spacing: PulseDesign.cardSpacing) {
            VStack(alignment: .leading, spacing: PulseDesign.cardSpacing * 0.6) {
                MileageHeroCard(distanceMillimeters: summary.totalMouseDistanceMillimeters)
                LandmarkProgressPanel(distanceMillimeters: summary.totalMouseDistanceMillimeters)
            }
            .frame(maxWidth: .infinity)

            SummaryCardsView(summary: summary, trend: model.trendPoints)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Section title used to break the Dashboard's long scroll into a few
/// scannable groups (Apple Health pattern). Rounded title3 + a short
/// coral accent capsule that gives the eye an anchor without shouting.
struct DashboardSectionHeader: View {

    let titleKey: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(titleKey, bundle: .pulse)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            Capsule()
                .fill(PulseDesign.coral.opacity(0.5))
                .frame(width: 28, height: 2)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// Inline Dashboard banner shown whenever one or more required
/// permissions (Input Monitoring / Accessibility) aren't granted.
/// Mirrors the menu-bar `PermissionAssistantView` but uses a full-width
/// style suited to the Dashboard's wider canvas. When nothing is
/// missing the view collapses to `EmptyView()` so it doesn't add
/// padding.
struct DashboardPermissionBanner: View {

    let permissions: PermissionSnapshot

    var body: some View {
        let missing = permissions.missingRequired
        if missing.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PulseDesign.amber)
                    Text("Pulse isn't collecting right now", bundle: .pulse)
                        .font(PulseDesign.cardTitleFont)
                }
                Text("Grant the permissions below in System Settings, then relaunch Pulse. Until then the numbers on this page won't update.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(missing, id: \.self) { permission in
                        Button {
                            if let url = permission.systemSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label {
                                Text("Open \(localizedPermissionName(permission))", bundle: .pulse)
                            } icon: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                    }
                }
            }
            .padding(PulseDesign.cardPadding * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius)
                    .fill(PulseDesign.amber.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius)
                    .strokeBorder(PulseDesign.amber.opacity(0.25), lineWidth: 0.5)
            )
        }
    }
}

/// F-49b — shown at the top of the Dashboard the next time the app
/// opens after it was killed abnormally (crash, SIGKILL, forced
/// shutdown). Deliberately quiet visual — amber accent, not coral,
/// because the user has already lost data-collection continuity
/// for the missed window and the last thing we want is to make
/// them feel panicked about it. Two actions: reveal the most recent
/// diagnostic report in Finder, or acknowledge and dismiss.
struct CrashBeaconBanner: View {

    @ObservedObject var beacon: CrashBeacon

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(PulseDesign.amber)
                .font(.system(size: 18, weight: .medium))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pulse exited unexpectedly last time", bundle: .pulse)
                    .font(.body.weight(.medium))
                Text("A diagnostic report was saved by macOS. Open it to see the stack trace, or dismiss this banner — it won't reappear unless another crash happens.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        beacon.revealLatestCrashReport()
                    } label: {
                        Text("Show crash report", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.link)
                    Button {
                        beacon.acknowledge()
                    } label: {
                        Text("Dismiss", bundle: .pulse)
                            .font(.footnote)
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(14)
        .background(PulseDesign.amber.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PulseDesign.amber.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// F-25 lifetime-tier celebration. Fires the first time cumulative
/// mouse distance (across every day the user has run Pulse) crosses
/// a new `LandmarkLibrary` landmark. Visually bolder than the daily
/// `MilestoneAchievementBanner` — trophy icon + coral fill — because
/// these are rare, earned events (Pacific / equator will take years).
struct LifetimeMilestoneBanner: View {

    let achievement: LandmarkAchievement
    let onDismiss: () -> Void

    var body: some View {
        let landmarkName = PulseFormat.localizedLandmarkName(for: achievement.landmark)
        let landmarkDistance = PulseFormat.metersWhole(achievement.landmark.distanceMeters)
        let lifetimeSoFar = PulseFormat.metersWhole(achievement.metersReached)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trophy.fill")
                .font(.title2)
                .foregroundStyle(PulseDesign.coral)
                .pulseHeartbeat(amplitude: .hero)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lifetime milestone", bundle: .pulse)
                    .font(PulseDesign.labelFont)
                    .tracking(0.3)
                    .foregroundStyle(PulseDesign.coral)
                Text("Across every day you've used Pulse, your cursor has crossed \(landmarkName) — \(landmarkDistance).", bundle: .pulse)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lifetime total: \(lifetimeSoFar).", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss", bundle: .pulse))
        }
        .padding(14)
        .background(PulseDesign.coral.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PulseDesign.coral.opacity(0.35), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One-shot celebration banner that fires when today's cursor distance
/// crosses a new `LandmarkLibrary` landmark for the first time (F-25
/// "里程碑彩蛋"). Persistence of the highest-acknowledged landmark for
/// the day lives in `DashboardModel`; this view is pure presentation.
struct MilestoneAchievementBanner: View {

    let achievement: LandmarkAchievement
    let onDismiss: () -> Void

    var body: some View {
        let landmarkName = PulseFormat.localizedLandmarkName(for: achievement.landmark)
        let landmarkDistance = PulseFormat.metersWhole(achievement.landmark.distanceMeters)
        let movedSoFar = PulseFormat.metersWhole(achievement.metersReached)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(PulseDesign.sage)
            VStack(alignment: .leading, spacing: 4) {
                Text("Milestone reached", bundle: .pulse)
                    .font(PulseDesign.labelFont)
                    .tracking(0.3)
                    .foregroundStyle(PulseDesign.sage)
                Text("Today's mileage just hit \(landmarkName) — \(landmarkDistance).", bundle: .pulse)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You've moved \(movedSoFar) so far today.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss", bundle: .pulse))
        }
        .pulseFeaturedCard()
    }
}

/// Hero card for the "mouse mileage" feature (F-07). Shows today's cursor
/// distance in a prominent typeface with a dramatic landmark comparison
/// underneath — the "哇" moment the roadmap flags as the MVP's addictive
/// hook. The comparison text comes from `LandmarkLibrary`, which preserves
/// drama at both first-day (tiny fractions of a pool) and long-running
/// (multiples of a marathon) scales.
struct MileageHeroCard: View {

    let distanceMillimeters: Double
    let library: LandmarkLibrary

    init(distanceMillimeters: Double, library: LandmarkLibrary = .standard) {
        self.distanceMillimeters = distanceMillimeters
        self.library = library
    }

    var body: some View {
        let meters = distanceMillimeters / 1_000.0
        let comparison = library.bestMatch(forMeters: meters)

        ZStack(alignment: .topTrailing) {
            // Concentric-circle heartbeat accent in the top-right,
            // breathing at the `.hero` amplitude (+8% every 3.2s).
            pulseGlyph
                .padding([.top, .trailing], 18)

            VStack(alignment: .leading, spacing: 12) {
                Text("Mouse mileage today", bundle: .pulse)
                    .font(PulseDesign.labelFont)
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Text(PulseFormat.distance(millimeters: distanceMillimeters))
                    .font(PulseDesign.heroFont)
                    .monospacedDigit()
                    .foregroundStyle(PulseDesign.coral)
                Text(PulseFormat.landmarkComparisonSentence(for: comparison))
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .opacity(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseHeroCard()
    }

    /// Coral ECG-waveform glyph that breathes — same visual as the
    /// menu-bar icon and the app icon, so all three "脉搏" surfaces
    /// reinforce each other. A26b shipped this as three faint
    /// concentric circles, but the outer two (10% / 18% opacity coral)
    /// were invisible against the off-white card surface and the
    /// remaining 8pt center dot read as an alert-style notification
    /// badge instead of a pulse anchor.
    private var pulseGlyph: some View {
        Image(systemName: "waveform.path.ecg")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(PulseDesign.coral.opacity(0.7))
            .pulseHeartbeat(amplitude: .hero)
    }
}

/// Panel shown under `MileageHeroCard` listing a fixed set of anchor
/// landmarks with a progress bar per row. Complements the hero card's
/// single dramatic comparison with a multi-anchor view — the prototype's
/// "which landmarks have I crossed and how far to the next" story.
///
/// Anchor selection is fixed rather than adaptive so the list stays
/// stable week to week (progress bars re-fill smoothly instead of
/// re-ordering). The four picked span four orders of magnitude
/// (1 km → 15 500 km) so every user sees movement on at least one bar.
/// Top-of-Dashboard card that renders whichever preset goals the user
/// has opted into from Settings. When nobody has opted in the parent
/// hides this whole card — per review §2.3, users without intent see
/// nothing, users with intent get a feedback loop.
struct GoalsCard: View {

    let progress: [GoalProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today I want to", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)
            VStack(spacing: 10) {
                ForEach(progress) { row in
                    GoalProgressRow(progress: row)
                }
            }
        }
        .pulseFeaturedCard()
    }
}

struct GoalProgressRow: View {

    let progress: GoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(GoalPresetLocalizer.title(for: progress.definition))
                    .font(.footnote)
                Spacer()
                if progress.isAchieved {
                    Label {
                        Text("Achieved", bundle: .pulse)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(PulseDesign.sage)
                } else {
                    Text(GoalPresetLocalizer.progressText(for: progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PulseDesign.warmGray(0.08))
                    Capsule()
                        .fill(progress.isAchieved ? PulseDesign.sage : PulseDesign.coral)
                        .frame(width: geo.size.width * CGFloat(progress.fractionTowardsTarget))
                }
            }
            .frame(height: 4)
        }
    }
}

/// Translates a `GoalDefinition` into the presentation strings shown in
/// the Dashboard card and the Settings toggle. Lives in the app layer
/// so PulseCore stays locale-free.
extension Locale {
    /// `true` when the current locale prefers Simplified Chinese.
    /// Workaround for the xcstrings compile step not emitting
    /// dot-separated keys into the packaged resource bundle —
    /// several localizers fall back to a manual Swift pivot on this
    /// flag until the catalog pipeline is fixed.
    static var prefersChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }
}

/// Dot-separated keys in `Localizable.xcstrings` aren't resolving
/// against the app's packaged resource bundle in release builds
/// (neither through `Text(LocalizedStringKey, bundle:)` nor through
/// `NSLocalizedString(key:, bundle:)`). The xcstrings compile step
/// appears to skip these entries for both en + zh-Hans, so the
/// lookup returns the raw key. Rather than fight the catalog, the
/// localizers below carry a manual `zh-Hans` fallback pivoted on
/// `Locale.current`. Once the xcstrings pipeline is fixed the
/// manual pivots can go back to being straight bundle lookups.
enum GoalPresetLocalizer {

    static func title(for goal: GoalDefinition) -> String {
        let zh = Locale.prefersChinese
        switch goal.id {
        case "focus.active.3h":
            return zh ? "累计活跃 3 小时" : "3 hours of active time"
        case "focus.longest.45m":
            return zh ? "一口气专注 45 分钟" : "A 45-minute focus streak"
        case "switches.under30":
            return zh ? "应用切换不超过 30 次" : "Under 30 app switches"
        case "keystrokes.5k":
            return zh ? "敲满 5,000 键" : "5,000 keystrokes"
        default:
            return goal.id
        }
    }

    static func subtitle(for goal: GoalDefinition) -> String {
        let zh = Locale.prefersChinese
        switch goal.id {
        case "focus.active.3h":
            return zh ? "今天总活跃时间达到 3 小时" : "Reach 3 hours of tracked activity today."
        case "focus.longest.45m":
            return zh ? "一次不中断的专注会话 ≥ 45 分钟" : "One uninterrupted focus session ≥ 45 minutes."
        case "switches.under30":
            return zh ? "把今天的应用切换次数控制在 30 以内" : "Keep today's app switches below 30."
        case "keystrokes.5k":
            return zh ? "今天累计按键 ≥ 5,000 次" : "Accumulate 5,000+ key presses today."
        default:
            return ""
        }
    }

    /// "1h 23m / 3h" style progress string, locale-aware. For "at most"
    /// goals, flips to "12 / 30 (below threshold)" shape.
    static func progressText(for progress: GoalProgress) -> String {
        let actual = progress.actualValue
        let target = progress.definition.target
        switch progress.definition.metric {
        case .activeSeconds, .longestFocusSeconds:
            return "\(PulseFormat.duration(seconds: Int(actual))) / \(PulseFormat.duration(seconds: Int(target)))"
        case .appSwitches, .keystrokes:
            return "\(PulseFormat.integer(Int(actual))) / \(PulseFormat.integer(Int(target)))"
        }
    }
}

struct LandmarkProgressPanel: View {

    let distanceMillimeters: Double

    /// Stable anchor set, ordered from smallest to largest.
    private static let anchorKeys: [String] = [
        "kilometer", "marathon", "beijing_gz", "pacific"
    ]

    private var rows: [(Landmark, Double)] {
        let meters = distanceMillimeters / 1_000.0
        let library = LandmarkLibrary.standard.landmarks
        return Self.anchorKeys.compactMap { key in
            library.first(where: { $0.key == key }).map { landmark in
                let ratio = landmark.distanceMeters > 0 ? meters / landmark.distanceMeters : 0
                return (landmark, ratio)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Landmarks", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)
            VStack(spacing: 10) {
                ForEach(rows, id: \.0.key) { row in
                    LandmarkProgressRow(landmark: row.0, ratio: row.1)
                }
            }
        }
        .pulseFeaturedCard()
    }
}

struct LandmarkProgressRow: View {

    let landmark: Landmark
    let ratio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if ratio >= 1 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(PulseDesign.sage)
                }
                Text(PulseFormat.localizedLandmarkName(for: landmark))
                    .font(.footnote)
                Spacer()
                Text(valueText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PulseDesign.warmGray(0.08))
                    Capsule()
                        .fill(ratio >= 1 ? PulseDesign.sage : PulseDesign.coral)
                        .frame(width: geo.size.width * min(1, max(0, ratio)))
                }
            }
            .frame(height: 4)
        }
    }

    private var valueText: String {
        if ratio >= 1 {
            let rounded = (ratio * 10).rounded() / 10
            return "\(rounded.formatted(.number.precision(.fractionLength(1))))×"
        } else {
            let pct = Int((ratio * 100).rounded())
            return "\(pct)%"
        }
    }
}

struct SummaryCardsView: View {

    let summary: TodaySummary
    let trend: [DailyTrendPoint]

    private static let narrative = NarrativeEngine.standard

    var body: some View {
        // Pinned 2 columns (instead of `.adaptive`) so the right-side
        // 6-tile grid in the "Today's pulse" section keeps a consistent
        // 3-row × 2-col shape no matter how wide the window grows. The
        // column widths flex to fill whatever space the parent gives.
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        LazyVGrid(columns: columns, spacing: 12) {
            SummaryMetricCard(
                titleKey: "Distance",
                value: PulseFormat.distance(millimeters: summary.totalMouseDistanceMillimeters),
                series: trend.map(\.mouseDistanceMillimeters)
            )
            SummaryMetricCard(
                titleKey: "Clicks",
                value: PulseFormat.integer(summary.totalMouseClicks),
                series: trend.map { Double($0.mouseClicks) }
            )
            SummaryMetricCard(
                titleKey: "Scrolls",
                value: PulseFormat.integer(summary.totalScrollTicks),
                series: trend.map { Double($0.scrollTicks) },
                narrativeSubtitle: scrollsNarrative
            )
            SummaryMetricCard(
                titleKey: "Keystrokes",
                value: PulseFormat.integer(summary.totalKeyPresses),
                series: trend.map { Double($0.keyPresses) },
                narrativeSubtitle: keystrokesNarrative
            )
            SummaryMetricCard(
                titleKey: "Active time",
                value: PulseFormat.duration(seconds: summary.totalActiveSeconds),
                series: [] // no per-day series for active time yet
            )
            SummaryMetricCard(
                titleKey: "Idle time",
                value: PulseFormat.duration(seconds: summary.totalIdleSeconds),
                series: trend.map { Double($0.idleSeconds) }
            )
        }
    }

    private var keystrokesNarrative: String? {
        Self.narrative
            .bestMatch(metric: .keystrokes, value: Double(summary.totalKeyPresses))
            .map { PulseFormat.narrativeSentence(for: $0) }
    }

    private var scrollsNarrative: String? {
        Self.narrative
            .bestMatch(metric: .scrollTicks, value: Double(summary.totalScrollTicks))
            .map { PulseFormat.narrativeSentence(for: $0) }
    }
}

/// One summary tile. Shows title + big value + optional 7-day sparkline
/// + optional delta-vs-yesterday chip + optional narrative subtitle. The
/// sparkline and delta come from the same `series`; passing an empty
/// series (or an all-zero one) hides both gracefully, so pre-rollup
/// installs don't render blank charts.
struct SummaryMetricCard: View {

    let titleKey: LocalizedStringKey
    let value: String
    let series: [Double]
    var narrativeSubtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(titleKey, bundle: .pulse)
                    .font(PulseDesign.labelFont)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                Spacer()
                if let delta = deltaVsYesterday {
                    DeltaChip(deltaFraction: delta)
                }
            }
            Text(value)
                .font(PulseDesign.metricFont)
            if let narrativeSubtitle {
                Text(narrativeSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if showSparkline {
                ZStack(alignment: .bottom) {
                    Sparkline(points: series, closed: true)
                        .fill(PulseDesign.coral.opacity(0.10))
                    Sparkline(points: series, closed: false)
                        .stroke(PulseDesign.coral, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                .frame(height: 22)
            }
        }
        .padding(PulseDesign.cardPadding * 0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius * 0.75)
                .fill(PulseDesign.warmGray(0.04))
        )
    }

    private var showSparkline: Bool {
        series.count >= 2 && !series.allSatisfy({ $0 == 0 })
    }

    /// Fractional change (yesterday → today). Returns nil when there is
    /// no yesterday (series < 2 points) or when yesterday was zero (can't
    /// normalise).
    private var deltaVsYesterday: Double? {
        guard series.count >= 2 else { return nil }
        let yesterday = series[series.count - 2]
        let today = series.last ?? 0
        guard yesterday > 0 else { return nil }
        return (today - yesterday) / yesterday
    }
}

/// Tiny ±N% chip next to metric titles — signals "vs yesterday"
/// movement. Uses `+` / `−` typographic marks and the Vital Pulse
/// sage/amber palette instead of the previous green/orange arrows.
struct DeltaChip: View {

    let deltaFraction: Double

    var body: some View {
        let pct = Int((deltaFraction * 100).rounded())
        let isUp = deltaFraction >= 0
        Text(isUp ? "+\(pct)%" : "−\(abs(pct))%")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isUp ? PulseDesign.deltaPositive : PulseDesign.deltaNegative)
    }
}

/// Line + optional area sparkline that stretches to fill its container.
/// Uses raw `Path` (not SwiftUI Charts) because Chart has more overhead
/// than warranted for a 40×22 tile. When `closed` is true, a baseline +
/// closing segment at the bottom make the shape fillable, which the
/// summary-card layout uses for a soft area tint under the line.
struct Sparkline: Shape {

    let points: [Double]
    let closed: Bool

    init(points: [Double], closed: Bool = false) {
        self.points = points
        self.closed = closed
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let maxVal = max(points.max() ?? 1, 1)
        let step = points.count > 1 ? rect.width / CGFloat(points.count - 1) : rect.width
        for (index, value) in points.enumerated() {
            let x = CGFloat(index) * step
            let normalised = maxVal > 0 ? CGFloat(value / maxVal) : 0
            let y = rect.height * (1 - normalised)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

/// 7-day trend line (F-01, basic). Plots total intentional events
/// (`keyPresses + mouseClicks`) per calendar day so the user can see
/// whether today trends with or against their recent rhythm. Empty days
/// render as a 0 point so the line stays continuous.
struct WeekTrendChart: View {

    let points: [DailyTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly trend", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)
            if points.allSatisfy({ $0.totalEvents == 0 }) {
                Text("No rolled-up activity yet. Check back once hourly roll-ups have run.", bundle: .pulse)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Events", point.totalEvents)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(PulseDesign.coral)

                    AreaMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Events", point.totalEvents)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [PulseDesign.coral.opacity(0.18), PulseDesign.coral.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    PointMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Events", point.totalEvents)
                    )
                    .symbolSize(32)
                    .foregroundStyle(PulseDesign.coral)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
                        AxisGridLine()
                            .foregroundStyle(PulseDesign.warmGray(0.10))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(shortDay(date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
        .pulseFeaturedCard()
    }

    /// Short weekday name ("Mon" / "周一") via `DateFormatter` using
    /// `Locale.current`, so the chart x-axis reads correctly under both
    /// English and Chinese system settings.
    private func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

/// 24h × Nd activity heatmap (F-03). Days run top → bottom with today on
/// top; hours run left → right from 00:00 to 23:00. Each cell's opacity is
/// proportional to its share of the max-observed activity in the window.
/// Missing cells (no data rolled up for that hour) render at the minimum
/// opacity so the grid shape stays readable.
struct WeekHourlyHeatmap: View {

    let cells: [HeatmapCell]
    let days: Int

    private static let minOpacity: Double = 0.06
    private static let maxOpacity: Double = 0.95
    private static let hourLabels = [0, 6, 12, 18]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headlineText.font(PulseDesign.cardTitleFont)
            content
            insightFooter
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private var headlineText: some View {
        switch days {
        case ..<7:   Text("Recent heatmap",   bundle: .pulse)
        case 7:      Text("Weekly heatmap",   bundle: .pulse)
        case 8...14: Text("Two-week heatmap", bundle: .pulse)
        default:     Text("\(days)-day heatmap", bundle: .pulse)
        }
    }

    @ViewBuilder
    private var content: some View {
        let lookup = indexed(cells)
        let maxActivity = max(cells.map(\.activityCount).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<days, id: \.self) { dayOffset in
                HStack(spacing: 2) {
                    dayLabel(for: dayOffset)
                        .frame(width: 52, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        let activity = lookup[cellKey(day: dayOffset, hour: hour)] ?? 0
                        let intensity = Double(activity) / Double(maxActivity)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.heatColor(intensity: intensity))
                            .frame(height: 16)
                    }
                }
            }
            HStack(spacing: 2) {
                Color.clear.frame(width: 52, height: 12)
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.hourLabels.contains(hour) ? "\(hour)" : "")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var insightFooter: some View {
        if let peak = peakHour() {
            let descriptorKey = Self.descriptorKey(forHour: peak)
            let hourString = String(format: "%02d:00", peak)
            HStack(spacing: 6) {
                Text("Peak at \(hourString)", bundle: .pulse)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(descriptorKey, bundle: .pulse)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    /// Aggregate activity by hour-of-day across all cells; return the hour
    /// with the highest total. `nil` when there's nothing to summarise.
    private func peakHour() -> Int? {
        var byHour: [Int: Int] = [:]
        for cell in cells {
            byHour[cell.hour, default: 0] += cell.activityCount
        }
        return byHour.max(by: { $0.value < $1.value })?.key
    }

    /// Map a peak hour to a localised "morning / afternoon / evening /
    /// night" descriptor key. Four buckets keep the copy short and avoid
    /// edge-case phrasing.
    private static func descriptorKey(forHour hour: Int) -> LocalizedStringKey {
        switch hour {
        case 5..<12:  return "heatmap.peak.morning"
        case 12..<17: return "heatmap.peak.afternoon"
        case 17..<22: return "heatmap.peak.evening"
        default:      return "heatmap.peak.night"
        }
    }

    /// Maps intensity ∈ [0, 1] onto a single-colour opacity ramp in the
    /// Vital Pulse Coral hue. Replaces the previous HSB rainbow (green →
    /// yellow → orange → red) which made the dashboard look like a
    /// data-centre control panel. Empty hours still render at 0.04 so the
    /// grid shape stays readable against the card background.
    private static func heatColor(intensity: Double) -> Color {
        let clamped = max(0, min(1, intensity))
        let opacity = 0.04 + 0.82 * clamped  // 0.04 → 0.86
        return PulseDesign.coral.opacity(opacity)
    }

    @ViewBuilder
    private func dayLabel(for dayOffset: Int) -> some View {
        switch dayOffset {
        case 0:
            Text("Today", bundle: .pulse)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case 1:
            Text("Yday", bundle: .pulse)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        default:
            Text(shortDayName(dayOffset))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func shortDayName(_ dayOffset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
        return formatter.string(from: date)
    }

    private func cellKey(day: Int, hour: Int) -> Int {
        day * 24 + hour
    }

    private func indexed(_ cells: [HeatmapCell]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for cell in cells {
            result[cellKey(day: cell.dayOffset, hour: cell.hour)] = cell.activityCount
        }
        return result
    }
}

/// F-43 — Rhythm-section card that compares the last N days against
/// the N days before that across the four daily-trend metrics
/// (keystrokes, clicks, mouse distance, scrolls). Uses the same
/// `DeltaChip` visual language the per-tile "vs yesterday" chip
/// uses so "up %" feels consistent across the Dashboard. When the
/// previous period is all-zero the chip is replaced with a "new"
/// label — a 200%-style chip on an empty baseline would be noise.
struct WeekOverWeekCard: View {

    let comparison: PeriodComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("This week vs last", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
                Spacer()
                Text(
                    "\(comparison.currentPeriodDayCount)-day window",
                    bundle: .pulse
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(comparison.rows, id: \.metric) { row in
                    WeekOverWeekRow(row: row)
                }
            }
        }
        .pulseFeaturedCard()
    }
}

/// One metric's row inside `WeekOverWeekCard`. Title on the left,
/// current-period total in the middle, delta chip on the right.
struct WeekOverWeekRow: View {

    let row: PeriodComparisonRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.titleKey(for: row.metric), bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.formattedCurrent(for: row))
                .font(.body.monospacedDigit())
            if let delta = row.deltaFraction {
                DeltaChip(deltaFraction: delta)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("new", bundle: .pulse)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PulseDesign.deltaPositive)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private static func titleKey(for metric: PeriodMetric) -> LocalizedStringKey {
        switch metric {
        case .keystrokes:                return "Keystrokes"
        case .mouseClicks:               return "Clicks"
        case .mouseDistanceMillimeters:  return "Distance"
        case .scrollTicks:               return "Scrolls"
        }
    }

    private static func formattedCurrent(for row: PeriodComparisonRow) -> String {
        switch row.metric {
        case .mouseDistanceMillimeters:
            return PulseFormat.distance(millimeters: row.currentValue)
        default:
            return PulseFormat.integer(Int(row.currentValue.rounded()))
        }
    }
}

/// Foot-of-Dashboard diagnostics panel (F-49 "自检状态页" deepening).
/// Surfaces the data already carried in `HealthSnapshot` so users can
/// answer "Is Pulse actually working?" without opening the menu bar.
/// Highlights a prominent warning row if `isSilentlyFailing` triggers —
/// the most actionable signal after permissions.
struct DiagnosticsCard: View {

    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)

            if snapshot.isSilentlyFailing {
                Label {
                    Text("No writes in the last minute — Pulse may have lost permission or stopped.", bundle: .pulse)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.footnote)
                .foregroundStyle(PulseDesign.amber)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(PulseDesign.amber.opacity(0.10))
                )
            }

            metricRow(labelKey: "Last data point",
                      value: snapshot.lastWriteAt.map { PulseFormat.ago(from: $0, to: snapshot.capturedAt) }
                        ?? String(localized: "never", bundle: .pulse))
            metricRow(labelKey: "Last rollup",
                      value: mostRecentRollup.map { PulseFormat.ago(from: $0, to: snapshot.capturedAt) }
                        ?? String(localized: "never", bundle: .pulse))
            metricRow(labelKey: "Database size",
                      value: snapshot.databaseFileSizeBytes.map(PulseFormat.bytes) ?? "–")
            metricRow(labelKey: "Total ingest batches",
                      value: PulseFormat.integer(snapshot.writer.totalFlushes))

            if let error = snapshot.writer.lastErrorDescription,
               let errorAt = snapshot.writer.lastErrorAt {
                Divider().overlay(PulseDesign.warmGray(0.12))
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Last writer error", bundle: .pulse)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                    .foregroundStyle(PulseDesign.amber)
                    Text("\(PulseFormat.ago(from: errorAt, to: snapshot.capturedAt)): \(error)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func metricRow(labelKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(labelKey, bundle: .pulse)
                .font(.footnote)
            Spacer()
            Text(value)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var mostRecentRollup: Date? {
        [
            snapshot.rollupStamps.rawToSecond,
            snapshot.rollupStamps.secondToMinute,
            snapshot.rollupStamps.minuteToHour,
            snapshot.rollupStamps.foregroundAppToMin,
            snapshot.rollupStamps.minAppToHour,
            snapshot.rollupStamps.idleEventsToMin,
            snapshot.rollupStamps.purgeExpired
        ].compactMap { $0 }.max()
    }
}

/// Dashboard card for A27 cross-metric insights. Renders up to three
/// rule-fired observations, each as an icon + headline + body row.
/// Only shown when `insights` is non-empty; the empty state is the
/// absence of the card itself (avoids "nothing interesting today"
/// filler that would compete with real signal elsewhere on the
/// Dashboard).
///
/// Localization follows the same pattern as `DashboardModel`'s
/// formatted strings: `NSLocalizedString` + `String.localizedStringWithFormat`
/// with positional arguments, so the String Catalog can flip
/// interpolation order per language.
struct InsightsCard: View {

    let insights: [Insight]

    /// Copy the Dashboard-wide cache so a fresh InsightsCard on a
    /// re-render doesn't re-load every bundle's display name from
    /// `NSWorkspace`.
    private static let displayNameCache = BundleDisplayNameCache()

    /// At most three rows — past that the card becomes a wall of
    /// text and the first-glance value of the Dashboard suffers.
    private static let visibleLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(PulseDesign.coral)
                Text("Today's insights", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(insights.prefix(Self.visibleLimit))) { insight in
                    row(for: insight)
                }
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func row(for insight: Insight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: insight))
                .foregroundStyle(accent(for: insight.kind))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: headline(for: insight.payload))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(verbatim: body(for: insight.payload))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Presentation helpers

    private func icon(for insight: Insight) -> String {
        switch insight.payload {
        case .activityAnomaly(.above, _, _, _): "arrow.up.forward.circle"
        case .activityAnomaly(.below, _, _, _): "arrow.down.forward.circle"
        case .deepFocusStandout: "waveform.path.ecg"
        case .singleAppDominance: "circle.grid.cross"
        case .hourlyActivityAnomaly: "clock.badge.exclamationmark"
        case .streakAtRisk: "flame.circle"
        }
    }

    private func accent(for kind: Insight.Kind) -> Color {
        switch kind {
        case .celebratory: PulseDesign.coral
        case .curious: PulseDesign.coral.opacity(0.8)
        case .neutral: .secondary
        }
    }

    private func headline(for payload: InsightPayload) -> String {
        switch payload {
        case let .activityAnomaly(direction, percentOff, _, _):
            switch direction {
            case .above:
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Today is %lld%% busier than usual",
                        bundle: .pulse,
                        comment: "Insight headline — activity anomaly, above baseline"
                    ),
                    Int64(percentOff)
                )
            case .below:
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Today is %lld%% quieter than usual",
                        bundle: .pulse,
                        comment: "Insight headline — activity anomaly, below baseline"
                    ),
                    Int64(percentOff)
                )
            }
        case .deepFocusStandout:
            return String(
                localized: "Biggest focus stretch this week",
                bundle: .pulse,
                comment: "Insight headline — today's longest focus beats the weekly median"
            )
        case let .singleAppDominance(bundleId, _, _):
            let app = Self.displayNameCache.name(for: bundleId)
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Focused day in %@",
                    bundle: .pulse,
                    comment: "Insight headline — one app dominated today; %@ is display name"
                ),
                app
            )
        case let .hourlyActivityAnomaly(hour, direction, percentOff, _, _):
            let label = String(format: "%02d:00", hour)
            switch direction {
            case .above:
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Your %@ hour was %lld%% busier than usual",
                        bundle: .pulse,
                        comment: "Insight headline — hourly anomaly above baseline. %@ is HH:00, %lld is percent."
                    ),
                    label,
                    Int64(percentOff)
                )
            case .below:
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Your %@ hour was %lld%% quieter than usual",
                        bundle: .pulse,
                        comment: "Insight headline — hourly anomaly below baseline."
                    ),
                    label,
                    Int64(percentOff)
                )
            }
        case let .streakAtRisk(currentStreak, _, _):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Keep your %lld-day streak going",
                    bundle: .pulse,
                    comment: "Insight headline — streak at risk. %lld is the current streak in days."
                ),
                Int64(currentStreak)
            )
        }
    }

    private func body(for payload: InsightPayload) -> String {
        switch payload {
        case let .activityAnomaly(_, _, todayKeys, medianKeys):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Typical day: about %lld key presses. Today: %lld.",
                    bundle: .pulse,
                    comment: "Insight body — activity anomaly comparison numbers"
                ),
                Int64(medianKeys),
                Int64(todayKeys)
            )
        case let .deepFocusStandout(todaySec, _, bundleId, percentAbove):
            let app = Self.displayNameCache.name(for: bundleId)
            let duration = PulseFormat.duration(seconds: todaySec)
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "%@ in %@ — %lld%% longer than your weekly median.",
                    bundle: .pulse,
                    comment: "Insight body — deep focus standout; duration, app, percent"
                ),
                duration,
                app,
                Int64(percentAbove)
            )
        case let .singleAppDominance(bundleId, fraction, seconds):
            let app = Self.displayNameCache.name(for: bundleId)
            let duration = PulseFormat.duration(seconds: seconds)
            let percent = Int((fraction * 100).rounded())
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "%@ accounted for %lld%% of your active time (%@).",
                    bundle: .pulse,
                    comment: "Insight body — single app dominance; app, percent, duration"
                ),
                app,
                Int64(percent),
                duration
            )
        case let .hourlyActivityAnomaly(hour, _, _, todayCount, medianCount):
            let label = String(format: "%02d:00", hour)
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Usually about %lld events at %@. Today: %lld.",
                    bundle: .pulse,
                    comment: "Insight body — hourly anomaly comparison. %lld median, %@ HH:00, %lld today."
                ),
                Int64(medianCount),
                label,
                Int64(todayCount)
            )
        case let .streakAtRisk(_, activeHoursToday, hoursToQualify):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "%lld active hours so far today — %lld more and today counts toward the streak.",
                    bundle: .pulse,
                    comment: "Insight body — streak at risk. First %lld is hours logged today, second is hours remaining to qualify."
                ),
                Int64(activeHoursToday),
                Int64(hoursToQualify)
            )
        }
    }
}

/// Narrates today's single longest uninterrupted run in one app — the
/// "深度专注片段" the product review flags as the most under-exploited
/// signal we already collect. Empty state is a Landmark-style nudge; the
/// populated state pairs the raw duration with a `NarrativeEngine`
/// sentence ("≈ 3× a pomodoro") so the card fits the wider narrative
/// program A16 kicks off.
struct DeepFocusCard: View {

    let segment: FocusSegment?

    private static let displayNameCache = BundleDisplayNameCache()
    private static let narrative = NarrativeEngine.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(segment == nil ? 0.35 : 0.85)
                Text("Deep focus today", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            if let segment {
                filled(segment)
            } else {
                empty
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func filled(_ segment: FocusSegment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PulseFormat.duration(seconds: segment.durationSeconds))
                .font(PulseDesign.heroSecondaryFont)
                .monospacedDigit()
                .foregroundStyle(PulseDesign.coral)
            let app = Self.displayNameCache.name(for: segment.bundleId)
            let start = Self.clockTime(segment.startedAt)
            let end = Self.clockTime(segment.endedAt)
            Text("\(app) · \(start) – \(end)", bundle: .pulse)
                .font(.body)
                .foregroundStyle(.primary)
                .opacity(0.8)
            if let narrative = Self.narrative.bestMatch(
                metric: .focusDurationSeconds,
                value: Double(segment.durationSeconds)
            ) {
                Text(PulseFormat.narrativeSentence(for: narrative))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var empty: some View {
        Text("Still warming up — your longest focus streak shows up once you've spent 20+ minutes in one app without going idle.", bundle: .pulse)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}

/// F-09 — the "专注度环形图". Renders today's per-category foreground
/// time as a donut (deep focus / communication / browsing / other)
/// with the deep-focus percentage in the center and a legend below.
/// Per Q-01 (decision D) the categorisation is auto via
/// `AppCategoryClassifier`; user-whitelist overrides are deferred
/// to v1.3.
struct FocusDonutCard: View {

    let donut: FocusDonut

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chart.pie")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(0.85)
                Text("Focus breakdown", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            HStack(alignment: .top, spacing: 24) {
                FocusDonutShape(donut: donut)
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(donut.segments) { segment in
                        FocusDonutLegendRow(
                            segment: segment,
                            fraction: donut.totalSeconds > 0
                                ? Double(segment.seconds) / Double(donut.totalSeconds)
                                : 0
                        )
                    }
                }
            }
        }
        .pulseFeaturedCard()
    }
}

struct FocusDonutShape: View {

    let donut: FocusDonut

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let lineWidth = diameter * 0.18
            ZStack {
                Circle()
                    .strokeBorder(PulseDesign.warmGray(0.08), lineWidth: lineWidth)
                    .frame(width: diameter, height: diameter)
                donutRing(diameter: diameter, lineWidth: lineWidth)
                VStack(spacing: 0) {
                    Text("\(Int((donut.deepFocusFraction * 100).rounded()))%")
                        .font(PulseDesign.heroSecondaryFont)
                        .monospacedDigit()
                        .foregroundStyle(PulseDesign.coral)
                    Text("deep focus", bundle: .pulse)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func donutRing(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let total = max(donut.totalSeconds, 1)
        var cursor: Double = 0
        ZStack {
            ForEach(donut.segments) { segment in
                let fraction = Double(segment.seconds) / Double(total)
                let startFraction = cursor
                let endFraction = cursor + fraction
                let _ = (cursor = endFraction)
                if segment.seconds > 0 {
                    Circle()
                        .trim(from: startFraction, to: endFraction)
                        .stroke(
                            FocusDonutCategoryPalette.color(for: segment.category),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                }
            }
        }
    }
}

struct FocusDonutLegendRow: View {

    let segment: FocusDonutSegment
    let fraction: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(FocusDonutCategoryPalette.color(for: segment.category))
                .frame(width: 8, height: 8)
            Text(Self.title(for: segment.category))
                .font(.footnote)
            Spacer()
            Text("\(Int((fraction * 100).rounded()))% · \(PulseFormat.duration(seconds: segment.seconds))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Manually localised label — same catalog-compile workaround
    /// as `KeyboardPeakCard.Tier.localizedLabel`.
    private static func title(for category: AppCategory) -> String {
        let zh = Locale.prefersChinese
        switch category {
        case .deepFocus:     return zh ? "深度专注" : "Deep focus"
        case .communication: return zh ? "沟通协作" : "Communication"
        case .browsing:      return zh ? "浏览网页" : "Browsing"
        case .other:         return zh ? "其它"     : "Other"
        }
    }
}

enum FocusDonutCategoryPalette {
    static func color(for category: AppCategory) -> Color {
        switch category {
        case .deepFocus:     return PulseDesign.coral
        case .communication: return PulseDesign.amber
        case .browsing:      return PulseDesign.sage
        case .other:         return PulseDesign.warmGray(0.4)
        }
    }
}

/// F-12 — Dashboard card that headlines today's busiest typing minute.
/// Shows KPM + the clock time it hit + a descriptive tier label
/// ("hunt-and-peck" → "sprint"). Empty state matches DeepFocusCard's
/// so the Focus section reads consistently on day-zero.
///
/// Tier bands are deliberately coarse (five steps) — 5 WPM resolution
/// is pointless for "whoa, did I type that fast?" payoff. Values and
/// anchor names match the WPM ladder every touch-typing tutorial uses,
/// divided by ~5 chars/word to land in keys-per-minute.
struct KeyboardPeakCard: View {

    let peak: KeyPressPeakMinute?

    enum Tier: Int, CaseIterable {
        case huntAndPeck    // < 120 KPM ≈ < 24 WPM
        case casual         // 120 – 200 KPM ≈ 24 – 40 WPM
        case touchTypist    // 200 – 300 KPM ≈ 40 – 60 WPM
        case fast           // 300 – 400 KPM ≈ 60 – 80 WPM
        case sprint         // ≥ 400 KPM

        static func classify(_ kpm: Int) -> Tier {
            switch kpm {
            case ..<120:  return .huntAndPeck
            case ..<200:  return .casual
            case ..<300:  return .touchTypist
            case ..<400:  return .fast
            default:      return .sprint
            }
        }

        /// Manually localised label. Same catalog-compile
        /// workaround as `GoalPresetLocalizer` — the xcstrings
        /// pipeline drops dot-separated keys, so pivot on
        /// `Locale.prefersChinese` in Swift.
        var localizedLabel: String {
            let zh = Locale.prefersChinese
            switch self {
            case .huntAndPeck:  return zh ? "逐键寻找节奏"     : "hunt-and-peck pace"
            case .casual:       return zh ? "日常写作节奏"     : "casual typing pace"
            case .touchTypist:  return zh ? "盲打流畅节奏"     : "touch-typist pace"
            case .fast:         return zh ? "快速打字节奏"     : "fast-typist pace"
            case .sprint:       return zh ? "键盘冲刺节奏"     : "keyboard-sprint pace"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(peak == nil ? 0.35 : 0.85)
                Text("Peak typing minute", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            if let peak {
                filled(peak)
            } else {
                empty
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func filled(_ peak: KeyPressPeakMinute) -> some View {
        let tier = Tier.classify(peak.kpm)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PulseFormat.integer(peak.kpm))
                    .font(PulseDesign.heroSecondaryFont)
                    .monospacedDigit()
                    .foregroundStyle(PulseDesign.coral)
                Text("KPM", bundle: .pulse)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text("at \(Self.clockTime(peak.minuteStart))", bundle: .pulse)
                .font(.body)
                .foregroundStyle(.primary)
                .opacity(0.8)
            Text(tier.localizedLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        Text("No typing yet — once you've pressed a key this card will show today's busiest minute.", bundle: .pulse)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}

/// Dashboard card that summarises today's session rhythm — how many
/// sessions, avg / median duration, a classification label ranging
/// from "quick checker" to "deep worker". Backed by `SessionPosture`
/// per review §3.6 ("are you 5-min-per-jump or 40-min-per-slab?").
struct UsagePostureCard: View {

    let posture: SessionPosture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today's rhythm", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)
            if posture.sessionCount == 0 {
                Text("Not enough app-switch data yet — keep using your Mac and this card will tell you whether today is a checker day or a deep-worker day.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                filled
            }
        }
        .pulseFeaturedCard()
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 28) {
                stat(
                    label: Text("Sessions", bundle: .pulse),
                    value: "\(posture.sessionCount)"
                )
                stat(
                    label: Text("Median", bundle: .pulse),
                    value: PulseFormat.duration(seconds: posture.medianDurationSeconds)
                )
                stat(
                    label: Text("Average", bundle: .pulse),
                    value: PulseFormat.duration(seconds: posture.averageDurationSeconds)
                )
                stat(
                    label: Text("Longest", bundle: .pulse),
                    value: PulseFormat.duration(seconds: posture.longestDurationSeconds)
                )
                Spacer()
            }
            Text(Self.classificationSentence(for: posture), bundle: .pulse)
                .font(.body)
                .foregroundStyle(Self.classificationColor(for: posture))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func stat(label: Text, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label
                .font(PulseDesign.labelFont)
                .tracking(0.3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PulseDesign.metricFont)
        }
    }

    /// Color each classification according to its "depth":
    ///   deep-worker  → Sage (positive, steady)
    ///   steady-flow  → Sage
    ///   short-form   → Amber (not bad, just shallow)
    ///   checker      → Amber (more shallow)
    private static func classificationColor(for posture: SessionPosture) -> Color {
        posture.medianDurationSeconds >= 15 * 60 ? PulseDesign.sage : PulseDesign.amber
    }

    private static func classificationSentence(for posture: SessionPosture) -> LocalizedStringKey {
        let median = posture.medianDurationSeconds
        if median >= 30 * 60 {
            return "Deep-worker mode — most of your sessions today run half an hour or more."
        } else if median >= 15 * 60 {
            return "Steady flow — sessions are long enough to settle into real work."
        } else if median >= 5 * 60 {
            return "Short-form work — lots of 5-to-15-minute sessions today."
        } else {
            return "Checker mode — mostly quick dips today, not long-form focus."
        }
    }
}

/// F-10 — a full-day horizontal band showing which app had focus at
/// each moment. The bar spans 24h (not the partial-day slice) so the
/// user can visually place "now" against the whole day. The trailing
/// `dayEnd → midnight` portion stays visually empty — a stretched
/// 15h bar on a 15h-of-today timeline would be misleading.
///
/// Bundle colors come from a deterministic palette lookup
/// (`DayTimelineCard.color(for:)`) so the same app stays the same
/// color across refresh ticks, locales, and process restarts.
struct DayTimelineCard: View {

    let timeline: DayTimeline?

    private static let displayNameCache = BundleDisplayNameCache()
    private static let barHeight: CGFloat = 32
    private static let hourLabels = [0, 6, 12, 18]

    private static let palette: [Color] = [
        PulseDesign.sage,
        PulseDesign.coral,
        PulseDesign.amber,
        .blue,
        .purple,
        .teal,
        .indigo,
        .pink
    ]

    var body: some View {
        if let timeline, !timeline.isEmpty {
            populated(timeline)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func populated(_ timeline: DayTimeline) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(PulseDesign.sage)
                    .opacity(0.85)
                Text("Today's timeline", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            bar(timeline)
                .frame(height: Self.barHeight)
            axis
            legend(timeline)
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func bar(_ timeline: DayTimeline) -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let daySpan: TimeInterval = 86_400
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                    let offset = segment.startedAt.timeIntervalSince(timeline.dayStart)
                    let width = max(1, CGFloat(Double(segment.durationSeconds) / daySpan) * totalWidth)
                    Self.color(for: segment.bundleId)
                        .opacity(0.85)
                        .frame(width: width)
                        .offset(x: CGFloat(offset / daySpan) * totalWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.hourLabels.contains(hour) ? "\(hour)" : "")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func legend(_ timeline: DayTimeline) -> some View {
        let top = timeline.topBundles(limit: 3)
        if !top.isEmpty {
            HStack(spacing: 16) {
                ForEach(Array(top.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.color(for: entry.bundleId).opacity(0.85))
                            .frame(width: 8, height: 8)
                        Text(Self.displayNameCache.name(for: entry.bundleId))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(PulseFormat.duration(seconds: entry.totalSeconds))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Colour mapping

    /// Deterministic palette pick — same bundle id always gets the
    /// same color across refresh ticks, locale changes, and process
    /// restarts. Avoids `String.hashValue` (per-process randomised
    /// seed) and the ordering drift that would come with it.
    static func color(for bundleId: String) -> Color {
        var sum = 0
        for scalar in bundleId.unicodeScalars {
            sum &+= Int(scalar.value)
        }
        return palette[abs(sum) % palette.count]
    }
}

/// F-26 — today's rest recap. Walks completed `idle_entered` /
/// `idle_exited` pairs (and any still-open idle segment) and
/// surfaces count + longest + total. Complements the A15 "Idle time"
/// summary tile — the tile is a single aggregate number, this card
/// explains its shape (one 90-minute rest or ten 9-minute micro-pauses
/// are very different usage patterns).
///
/// Renders nothing when no rest has been recorded today — the A15
/// tile already carries the "0 minutes idle" case, a dedicated empty
/// card would be noise.
struct RestCard: View {

    let rest: RestDay

    var body: some View {
        if rest.count == 0 {
            EmptyView()
        } else {
            populated
        }
    }

    private var populated: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "cup.and.saucer")
                    .foregroundStyle(PulseDesign.sage)
                    .opacity(0.85)
                Text("Rests today", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            HStack(spacing: 28) {
                stat(
                    label: Text("Count", bundle: .pulse),
                    value: "\(rest.count)"
                )
                stat(
                    label: Text("Longest", bundle: .pulse),
                    value: PulseFormat.duration(seconds: rest.longestSeconds)
                )
                stat(
                    label: Text("Total", bundle: .pulse),
                    value: PulseFormat.duration(seconds: rest.totalSeconds)
                )
                Spacer()
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func stat(label: Text, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label
                .font(PulseDesign.labelFont)
                .tracking(0.3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PulseDesign.metricFont)
        }
    }
}

/// F-22 — today's "passive consumption" (screen-on idle while an app
/// was foregrounded). Surfaces the dominant bundle so the one-line
/// story reads "30 min while Safari was in front" — the classic
/// video / long-form read signature. Auto-hides when the day has no
/// qualifying time via the parent `if passive.totalSeconds > 0`.
struct PassiveConsumptionCard: View {

    let passive: PassiveConsumption

    private static let displayNameCache = BundleDisplayNameCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(0.85)
                Text("Passive consumption today", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            Text(PulseFormat.duration(seconds: passive.totalSeconds))
                .font(PulseDesign.heroSecondaryFont)
                .monospacedDigit()
                .foregroundStyle(PulseDesign.coral)
            if let top = passive.topBundle {
                let share = passive.totalSeconds > 0
                    ? Double(top.seconds) / Double(passive.totalSeconds)
                    : 0
                let app = Self.displayNameCache.name(for: top.bundleId)
                let percent = Int((share * 100).rounded())
                Text("Mostly while \(app) was in front (\(percent)%)", bundle: .pulse)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .opacity(0.8)
            }
            Text("Screen-on time with no input — watched, read, or stepped away while the app kept the foreground.", bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pulseFeaturedCard()
    }
}

/// F-27 — how many times the MacBook lid has been opened today,
/// with a seven-day sparkline for context. Desktop users get no
/// `lid_*` system events; when the 7-day history is empty the card
/// hides itself (no "0 opens" filler on a Mac Studio).
///
/// Semantically one lid-open = one "returned to the Mac" moment —
/// a concrete session count, not a noisy toggle tally.
struct LidCard: View {

    let todayOpens: Int
    let trend: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(PulseDesign.sage)
                    .opacity(todayOpens > 0 ? 0.85 : 0.45)
                Text("MacBook lid", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(todayOpens)")
                        .font(PulseDesign.heroSecondaryFont)
                        .monospacedDigit()
                        .foregroundStyle(todayOpens > 0 ? PulseDesign.sage : .secondary)
                    Text("opens today", bundle: .pulse)
                        .font(PulseDesign.labelFont)
                        .tracking(0.3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if trend.count >= 2 {
                    VStack(alignment: .trailing, spacing: 6) {
                        let pastAvg = Self.pastAverage(trend)
                        Text(
                            String.localizedStringWithFormat(
                                NSLocalizedString(
                                    "Avg past 7 days: %@",
                                    bundle: .pulse,
                                    comment: "F-27 LidCard — 7-day average lid-open count, already formatted."
                                ),
                                pastAvg
                            )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        let series = trend.map(Double.init)
                        ZStack(alignment: .bottom) {
                            Sparkline(points: series, closed: true)
                                .fill(PulseDesign.sage.opacity(0.10))
                            Sparkline(points: series, closed: false)
                                .stroke(PulseDesign.sage, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                        }
                        .frame(width: 80, height: 22)
                    }
                }
            }
        }
        .pulseFeaturedCard()
    }

    /// Average over the **prior** days in the trend (excludes today,
    /// which is the last slot). Formatted with one decimal when the
    /// result has a fractional part, integer otherwise — matches the
    /// SummaryCard conventions without reaching for `NumberFormatter`
    /// overhead on a tiny two-digit value.
    static func pastAverage(_ trend: [Int]) -> String {
        let past = trend.dropLast()
        guard !past.isEmpty else { return "0" }
        let avg = Double(past.reduce(0, +)) / Double(past.count)
        if avg.rounded() == avg {
            return String(Int(avg))
        }
        return String(format: "%.1f", avg)
    }
}

/// F-11 — 52-week continuity grid. One square per day, Sun-to-Sat
/// columns (locale-aware via `Calendar.firstWeekday`), colored by the
/// day's active-hour count. Headline = current streak; a secondary
/// "Longest: N" pairs the "don't break the chain" framing with proof
/// that the user has achieved long runs before.
struct ContinuityCard: View {

    let streak: ContinuityStreak?

    private static let cellSize: CGFloat = 10
    private static let cellSpacing: CGFloat = 3
    private static let cellCornerRadius: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .foregroundStyle(PulseDesign.sage)
                    .opacity(hasAnyActivity ? 0.85 : 0.35)
                Text("Continuity", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            if let streak, hasAnyActivity {
                filled(streak)
            } else {
                empty
            }
        }
        .pulseFeaturedCard()
    }

    private var hasAnyActivity: Bool {
        (streak?.days.contains { $0.activeHours > 0 }) ?? false
    }

    @ViewBuilder
    private func filled(_ streak: ContinuityStreak) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(streak.currentStreak)")
                        .font(PulseDesign.heroSecondaryFont)
                        .monospacedDigit()
                        .foregroundStyle(streak.currentStreak > 0 ? PulseDesign.sage : .secondary)
                    Text("current streak", bundle: .pulse)
                        .font(PulseDesign.labelFont)
                        .tracking(0.3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString(
                                "Longest: %lld",
                                bundle: .pulse,
                                comment: "Continuity card — longest streak in the window. %lld is days."
                            ),
                            Int64(streak.longestStreak)
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString(
                                "%lld of %lld days qualified",
                                bundle: .pulse,
                                comment: "Continuity card — qualifying days in the window. First %lld is qualifying, second is total."
                            ),
                            Int64(streak.qualifyingDays),
                            Int64(streak.windowDays)
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                }
            }
            grid(streak)
            if streak.currentStreak == 0, let today = streak.days.last, today.activeHours > 0 {
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Today: %lld active hours so far — a few more to qualify.",
                            bundle: .pulse,
                            comment: "Continuity card — footer shown when today has activity but has not yet crossed the threshold."
                        ),
                        Int64(today.activeHours)
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var empty: some View {
        Text("Every day you use your Mac for more than four hours lights up a square. Keep coming back — this card fills in over time.", bundle: .pulse)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func grid(_ streak: ContinuityStreak) -> some View {
        let columns = Self.layout(days: streak.days, calendar: .current)
        // Tight column spacing; fixed cell size. The whole grid
        // naturally becomes ~53 columns × (cellSize + cellSpacing) wide.
        HStack(alignment: .top, spacing: Self.cellSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: Self.cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: Self.cellCornerRadius)
                            .fill(Self.color(for: column[row], threshold: 4))
                            .frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
        }
    }

    // MARK: - Layout + coloring

    /// Assigns every `ContinuityDay` to a `(column, row)` slot so the
    /// rightmost column holds the current week, columns run left →
    /// right from oldest to newest, and rows are weekdays starting at
    /// `Calendar.firstWeekday`. Missing slots end up as `nil`.
    static func layout(days: [ContinuityDay], calendar: Calendar) -> [[ContinuityDay?]] {
        guard let newest = days.last else { return [] }
        let firstWeekday = calendar.firstWeekday
        func weekdayRow(_ date: Date) -> Int {
            let raw = calendar.component(.weekday, from: date) // 1..7
            return (raw - firstWeekday + 7) % 7
        }
        let newestRow = weekdayRow(newest.day)
        let newestDayStart = calendar.startOfDay(for: newest.day)

        var cellsByColFromRight: [Int: [Int: ContinuityDay]] = [:]
        var maxColFromRight = 0
        for day in days {
            let row = weekdayRow(day.day)
            let dayStart = calendar.startOfDay(for: day.day)
            let daysFromNewest = calendar.dateComponents([.day], from: dayStart, to: newestDayStart).day ?? 0
            // Days between the two week-start anchors; see design note
            // in the card documentation.
            let daysBetweenWeekStarts = daysFromNewest + row - newestRow
            let colFromRight = max(0, daysBetweenWeekStarts / 7)
            maxColFromRight = max(maxColFromRight, colFromRight)
            cellsByColFromRight[colFromRight, default: [:]][row] = day
        }
        let totalCols = maxColFromRight + 1
        var grid: [[ContinuityDay?]] = Array(repeating: Array(repeating: nil, count: 7), count: totalCols)
        for (colFromRight, rows) in cellsByColFromRight {
            let col = totalCols - 1 - colFromRight
            for (row, day) in rows {
                grid[col][row] = day
            }
        }
        return grid
    }

    /// 5-step gradient keyed to active-hour count, anchored to
    /// `PulseDesign.sage`. 0 hours renders as a faint surface tint so
    /// the grid's weekday structure stays visible on a blank slate.
    static func color(for day: ContinuityDay?, threshold: Int) -> Color {
        guard let day else { return Color.secondary.opacity(0.08) }
        let hours = day.activeHours
        if hours == 0 {
            return Color.secondary.opacity(0.08)
        } else if hours < threshold {
            // Some activity, didn't clear the bar.
            return PulseDesign.sage.opacity(0.25)
        } else if hours < threshold * 2 {
            return PulseDesign.sage.opacity(0.5)
        } else if hours < threshold * 3 {
            return PulseDesign.sage.opacity(0.75)
        } else {
            return PulseDesign.sage
        }
    }
}

/// Bundle passed to `MouseTrajectoryCard` — the raw histogram plus the
/// latest display snapshot so the rendered tile honors the display's
/// physical aspect ratio. `snapshot` may be `nil` on a first launch
/// where no `display_snapshots` row has been written yet; the card
/// falls back to a square tile in that case.
struct MouseTrajectoryTileData: Equatable {
    let histogram: MouseDisplayHistogram
    let snapshot: DisplayInfo?
}

/// F-04 — mouse-trail density heatmap per display. One tile per
/// display with any activity in `DashboardModel.trajectoryDays`. Each
/// tile renders its `MouseDensityRenderer` output on a background
/// `.task(id:)` so the main actor keeps moving while the CGImage is
/// produced. The card is omitted entirely when no display has cells
/// (see the `trajectoryTiles.isEmpty` guard in `DashboardView`).
struct MouseTrajectoryCard: View {

    let tiles: [MouseTrajectoryTileData]

    private var totalMoves: Int64 {
        tiles.reduce(into: Int64(0)) { $0 += $1.histogram.totalCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "scribble.variable")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(0.85)
                Text("Mouse trails", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            subtitle
            VStack(spacing: 16) {
                // Pass an ordinal position so the tile labels stay
                // unique when `display_snapshots` has multiple rows
                // claiming `is_primary = 1` (observed in real-Mac
                // dogfooding after a display reconfig). Single-tile
                // state keeps the "Primary display" wording; any
                // multi-tile layout falls back to "Display 1", ….
                ForEach(Array(tiles.enumerated()), id: \.element.histogram.displayId) { index, tile in
                    MouseTrajectoryTile(
                        tile: tile,
                        ordinal: index + 1,
                        isOnlyTile: tiles.count == 1
                    )
                }
            }
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private var subtitle: some View {
        if totalMoves > 0 {
            let formatted = totalMoves.formatted(.number)
            Text(
                String.localizedStringWithFormat(
                    NSLocalizedString(
                        "%@ moves · last 7 days",
                        bundle: .pulse,
                        comment: "F-04 MouseTrajectoryCard — subtitle showing total mouse-move count recorded across all displays in the window."
                    ),
                    formatted
                )
            )
            .font(PulseDesign.labelFont)
            .tracking(0.3)
            .foregroundStyle(.secondary)
        } else {
            Text("No mouse movement recorded yet.", bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One tile inside `MouseTrajectoryCard`. Renders the display's
/// density heatmap as a `CGImage` computed via `.task(id:)` so the
/// work happens off the main actor on first appearance and whenever
/// the histogram changes. Aspect ratio comes from the latest
/// `display_snapshots` row for this display; tiles fall back to a
/// square when no snapshot is available yet.
private struct MouseTrajectoryTile: View {

    let tile: MouseTrajectoryTileData
    /// 1-based position in the parent's tile list; used to label
    /// "Display 1 / 2 / …" when more than one tile is visible.
    let ordinal: Int
    /// `true` when this is the only tile rendered — the parent
    /// flips to this when the user has a single display, which lets
    /// the card keep its concise "Primary display" label instead
    /// of the noisier "Display 1".
    let isOnlyTile: Bool

    @State private var renderedImage: CGImage?

    private static let renderer = MouseDensityRenderer()

    private var aspectRatio: CGFloat {
        if let snapshot = tile.snapshot, snapshot.heightPoints > 0 {
            return CGFloat(snapshot.widthPoints) / CGFloat(snapshot.heightPoints)
        }
        return 1.0
    }

    private var displayLabel: String {
        if isOnlyTile {
            return NSLocalizedString(
                "Primary display",
                bundle: .pulse,
                comment: "F-04 MouseTrajectoryCard — tile label for the sole display."
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "Display %lld",
                bundle: .pulse,
                comment: "F-04 MouseTrajectoryCard — tile label for the n-th display."
            ),
            Int64(ordinal)
        )
    }

    /// `true` when the histogram has so few hits that the rendered
    /// heatmap is effectively invisible against any background.
    /// Below this threshold the tile shows a "limited activity"
    /// placeholder; the rendered image is still produced (cheap) but
    /// hidden so the user isn't staring at a near-blank rectangle.
    private static let sparseThreshold: Int64 = 200

    private var isSparse: Bool {
        tile.histogram.totalCount < Self.sparseThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayLabel)
                    .font(PulseDesign.labelFont)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tile.histogram.totalCount.formatted(.number))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack {
                // Bumped from `0.08` to `0.16` so the tile reads as a
                // "screen" plate even when the heatmap density is
                // concentrated in a few cells (typical for a non-
                // primary monitor that the user only mouses across
                // briefly). Without this the tile looks broken.
                RoundedRectangle(cornerRadius: 8)
                    .fill(PulseDesign.warmGray(0.16))
                if let image = renderedImage, !isSparse {
                    // `.resizable()` without a `.aspectRatio(.fit)` lets
                    // the square 128×128-cell CGImage stretch into the
                    // container's display-aspect rectangle, which is
                    // what the user expects ("this is what my screen
                    // looks like, density-wise"). The surrounding ZStack
                    // supplies the aspect via the modifier below.
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                } else if isSparse {
                    sparsePlaceholder
                }
                // Faint coral border to anchor the tile as a "screen
                // silhouette" — without it, a sparsely-populated
                // heatmap blends into the surrounding card and reads
                // as a bug. 1pt at 18% opacity is intentionally just
                // visible, not a hard frame.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(PulseDesign.coral.opacity(0.18), lineWidth: 1)
            }
            // Size the tile to the display's real aspect, capped at a
            // fixed max height so the Dashboard card doesn't balloon
            // vertically when the user has a wide display + a tall
            // Dashboard window. `.fit` + `maxHeight` combine to pick
            // whichever dimension hits the cap first.
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Self.maxTileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .task(id: tile.histogram) {
            // `.task(id:)` runs a child Task off the view-update
            // critical path; the ~10–40 ms render therefore doesn't
            // stall the DashboardModel refresh. Re-runs automatically
            // whenever the histogram changes.
            let image = Self.renderer.render(tile.histogram)
            self.renderedImage = image
        }
    }

    /// Centred caption shown inside the tile when
    /// `tile.histogram.totalCount < sparseThreshold`. Better signal
    /// than a near-invisible heatmap on a display the user only
    /// briefly visited.
    private var sparsePlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "scribble")
                .font(.title3)
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text("Limited movement on this display yet.", bundle: .pulse)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
    }

    /// Tile height cap. 220pt on a 16:10 display gives a ~352pt wide
    /// tile — comfortable inside the Apps section without forcing the
    /// whole card to scroll when the user has multiple displays
    /// stacked.
    private static let maxTileHeight: CGFloat = 220
}

/// F-08 — the "键盘热力图". Renders a US-QWERTY grid with per-key
/// counts as a `sage → coral` intensity ramp. Empty / opt-out
/// states:
///
/// - **Not opted in (`pulse.collection.captureKeycodes == false`)**:
///   shows a short explanation + toggle CTA. Flipping the toggle
///   writes the preference; the live event tap checks the same key
///   on every keyDown and starts folding keycodes into the buffer.
///   Per Q-06 / docs/05-privacy.md §4.1, capture is explicitly opt-in.
/// - **Opted in but empty**: "Typing data will start accumulating…"
///   Once the user has actually typed with capture on, the grid
///   renders. No mock / demo data ever shows here.
struct KeyboardHeatmapCard: View {

    let keyCodes: [KeyCodeCount]

    @AppStorage("pulse.collection.captureKeycodes")
    private var captureEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.3.offgrid")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(captureEnabled ? 0.85 : 0.35)
                Text("Keyboard heatmap", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            if !captureEnabled {
                optInState
            } else if keyCodes.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .pulseFeaturedCard()
    }

    private var optInState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keycode capture is off by default. Enable it to see which keys you press most — only counts per key leave the event tap, never content or timing.", bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                captureEnabled = true
            } label: {
                Text("Enable keyboard heatmap", bundle: .pulse)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        Text("Typing data will start accumulating on the next keydown. Come back after a writing session.", bundle: .pulse)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private var grid: some View {
        let byKey = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.keyCode, $0.count) })
        let maxCount = max(1, keyCodes.map(\.count).max() ?? 1)
        return VStack(spacing: 4) {
            ForEach(Self.rows.indices, id: \.self) { idx in
                HStack(spacing: 4) {
                    ForEach(Self.rows[idx], id: \.keyCode) { key in
                        KeyboardHeatmapKey(
                            label: key.label,
                            count: byKey[key.keyCode] ?? 0,
                            maxCount: maxCount
                        )
                    }
                }
            }
        }
    }

    private struct Key: Hashable {
        let keyCode: UInt16
        let label: String
    }

    /// Rows of the US-QWERTY layout we render. Deliberately
    /// truncated to the keys with visible count payoff — function
    /// keys / numpad / modifiers add clutter without insight.
    private static let rows: [[Key]] = [
        [
            Key(keyCode: 50,  label: "`"),
            Key(keyCode: 18,  label: "1"),
            Key(keyCode: 19,  label: "2"),
            Key(keyCode: 20,  label: "3"),
            Key(keyCode: 21,  label: "4"),
            Key(keyCode: 23,  label: "5"),
            Key(keyCode: 22,  label: "6"),
            Key(keyCode: 26,  label: "7"),
            Key(keyCode: 28,  label: "8"),
            Key(keyCode: 25,  label: "9"),
            Key(keyCode: 29,  label: "0"),
            Key(keyCode: 27,  label: "-"),
            Key(keyCode: 24,  label: "="),
            Key(keyCode: 51,  label: "⌫")
        ],
        [
            Key(keyCode: 48,  label: "⇥"),
            Key(keyCode: 12,  label: "Q"),
            Key(keyCode: 13,  label: "W"),
            Key(keyCode: 14,  label: "E"),
            Key(keyCode: 15,  label: "R"),
            Key(keyCode: 17,  label: "T"),
            Key(keyCode: 16,  label: "Y"),
            Key(keyCode: 32,  label: "U"),
            Key(keyCode: 34,  label: "I"),
            Key(keyCode: 31,  label: "O"),
            Key(keyCode: 35,  label: "P"),
            Key(keyCode: 33,  label: "["),
            Key(keyCode: 30,  label: "]"),
            Key(keyCode: 42,  label: "\\")
        ],
        [
            Key(keyCode: 0,   label: "A"),
            Key(keyCode: 1,   label: "S"),
            Key(keyCode: 2,   label: "D"),
            Key(keyCode: 3,   label: "F"),
            Key(keyCode: 5,   label: "G"),
            Key(keyCode: 4,   label: "H"),
            Key(keyCode: 38,  label: "J"),
            Key(keyCode: 40,  label: "K"),
            Key(keyCode: 37,  label: "L"),
            Key(keyCode: 41,  label: ";"),
            Key(keyCode: 39,  label: "'"),
            Key(keyCode: 36,  label: "↩")
        ],
        [
            Key(keyCode: 6,   label: "Z"),
            Key(keyCode: 7,   label: "X"),
            Key(keyCode: 8,   label: "C"),
            Key(keyCode: 9,   label: "V"),
            Key(keyCode: 11,  label: "B"),
            Key(keyCode: 45,  label: "N"),
            Key(keyCode: 46,  label: "M"),
            Key(keyCode: 43,  label: ","),
            Key(keyCode: 47,  label: "."),
            Key(keyCode: 44,  label: "/")
        ],
        [
            Key(keyCode: 49,  label: "␣")
        ]
    ]
}

/// One key tile in `KeyboardHeatmapCard`'s grid. Colour intensity
/// is `count / maxCount` clamped to [0, 1], ramped sage → coral on
/// top of a faint warmGray base so zero-count keys stay visible
/// but muted.
struct KeyboardHeatmapKey: View {

    let label: String
    let count: Int
    let maxCount: Int

    var body: some View {
        let intensity = min(1.0, Double(count) / Double(max(1, maxCount)))
        let tint = Color(
            red:   (1.0 - intensity) * 0.55 + intensity * 0.95,
            green: (1.0 - intensity) * 0.70 + intensity * 0.45,
            blue:  (1.0 - intensity) * 0.55 + intensity * 0.35,
            opacity: 0.25 + intensity * 0.65
        )
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(tint)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(intensity > 0.55 ? Color.white : Color.primary.opacity(0.7))
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }
}

/// F-33 — the "快捷键使用榜". Bar list of today's most-used cmd/ctrl/
/// opt shortcut combos. Auto-hides at day-zero via the parent's
/// `if !model.shortcutsToday.isEmpty`. Combo strings are rendered
/// into human-friendly form (`cmd+c` → `⌘C`) inline so the list
/// reads like the system's menu-bar shortcut hints.
struct ShortcutLeaderboardCard: View {

    let rows: [ShortcutUsageRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "command.circle")
                    .foregroundStyle(PulseDesign.coral)
                    .opacity(0.85)
                Text("Top shortcuts today", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
            }
            let maxCount = Double(rows.first?.count ?? 1)
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    ShortcutLeaderboardRow(row: row, maxCount: maxCount)
                }
            }
        }
        .pulseFeaturedCard()
    }
}

struct ShortcutLeaderboardRow: View {

    let row: ShortcutUsageRow
    let maxCount: Double

    var body: some View {
        let fraction = maxCount > 0 ? Double(row.count) / maxCount : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.display(combo: row.combo))
                    .font(.body.monospaced())
                Spacer()
                Text(PulseFormat.integer(row.count))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PulseDesign.warmGray(0.08))
                    Capsule()
                        .fill(PulseDesign.coral)
                        .frame(width: geo.size.width * CGFloat(max(0.02, fraction)))
                }
            }
            .frame(height: 4)
        }
    }

    /// Render a canonical combo string (`cmd+shift+s`) as the glyph
    /// form macOS users recognise (`⇧⌘S`). Falls back to the raw
    /// string when a component isn't in the table.
    static func display(combo: String) -> String {
        let parts = combo.split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return combo }
        var modifiers = ""
        var keyPart = ""
        for part in parts {
            switch part {
            case "ctrl":   modifiers += "⌃"
            case "opt":    modifiers += "⌥"
            case "shift":  modifiers += "⇧"
            case "cmd":    modifiers += "⌘"
            default:
                keyPart = keyDisplay(for: part)
            }
        }
        return modifiers + keyPart
    }

    private static func keyDisplay(for name: String) -> String {
        switch name {
        case "return":        return "↩"
        case "tab":           return "⇥"
        case "space":         return "␣"
        case "delete":        return "⌫"
        case "escape":        return "⎋"
        case "forwardDelete": return "⌦"
        case "left":          return "←"
        case "right":         return "→"
        case "up":            return "↑"
        case "down":          return "↓"
        case "backtick":      return "`"
        case "minus":         return "-"
        case "equal":         return "="
        case "leftBracket":   return "["
        case "rightBracket":  return "]"
        case "quote":         return "'"
        case "semicolon":     return ";"
        case "backslash":     return "\\"
        case "comma":         return ","
        case "slash":         return "/"
        case "period":        return "."
        default:
            return name.uppercased()
        }
    }
}

struct AppRankingChart: View {

    let rows: [AppUsageRow]

    private static let displayNameCache = BundleDisplayNameCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top apps", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)
            if rows.isEmpty {
                Text("No app activity recorded yet today.", bundle: .pulse)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Seconds", row.secondsUsed),
                        y: .value("App", displayName(for: row.bundleId))
                    )
                    .foregroundStyle(PulseDesign.coral.opacity(0.85))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(PulseFormat.duration(seconds: row.secondsUsed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.primary)
                    }
                }
                .frame(height: max(120, CGFloat(rows.count) * 32))
            }
        }
        .pulseFeaturedCard()
    }

    private func displayName(for bundleId: String) -> String {
        Self.displayNameCache.name(for: bundleId)
    }
}

/// Resolves macOS bundle identifiers (e.g. `com.apple.Safari`) to the
/// human-readable display name visible to the user (e.g. "Safari").
/// Looks up the installed app via `NSWorkspace`, reads
/// `CFBundleDisplayName` / `CFBundleName` from the target bundle, and
/// memoises the result because every Dashboard refresh hits the same
/// handful of bundle IDs. Falls back to the raw bundle string for apps
/// that aren't installed (or aren't resolvable) so the UI never shows
/// an empty row.
final class BundleDisplayNameCache: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func name(for bundleId: String) -> String {
        lock.lock()
        if let cached = cache[bundleId] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.resolve(bundleId)
        lock.lock()
        cache[bundleId] = resolved
        lock.unlock()
        return resolved
    }

    private static func resolve(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let bundle = Bundle(url: url) else {
            return bundleId
        }
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty {
            return display
        }
        if let plain = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !plain.isEmpty {
            return plain
        }
        return bundleId
    }
}

struct CountersView: View {

    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(labelKey: "Mouse moves (raw)",  value: snapshot.l0Counts.mouseMoves)
            row(labelKey: "Mouse clicks (raw)", value: snapshot.l0Counts.mouseClicks)
            row(labelKey: "Key events (raw)",   value: snapshot.l0Counts.keyEvents)
            row(labelKey: "Total flushes",      value: snapshot.writer.totalFlushes)
            if let last = snapshot.lastWriteAt {
                rowText(labelKey: "Last write", value: PulseFormat.ago(from: last, to: snapshot.capturedAt))
            } else {
                rowText(labelKey: "Last write", value: String(localized: "never", bundle: .pulse))
            }
            if let bytes = snapshot.databaseFileSizeBytes {
                rowText(labelKey: "DB size", value: PulseFormat.bytes(bytes))
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func row(labelKey: LocalizedStringKey, value: Int) -> some View {
        HStack {
            Text(labelKey, bundle: .pulse)
            Spacer()
            Text(PulseFormat.integer(value))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func rowText(labelKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(labelKey, bundle: .pulse)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

struct PermissionList: View {

    let snapshot: PermissionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Only the two permissions Pulse actually depends on are
            // shown here. Calendars / Location / Notifications are
            // declared for future features but exposing them as
            // "未决定" today reads as if the user has outstanding
            // setup when they don't — keep them hidden until they
            // gate real functionality.
            ForEach(PermissionList.visible, id: \.self) { permission in
                HStack {
                    Text(localizedPermissionName(permission))
                    Spacer()
                    Text(localizedPermissionStatus(snapshot.statuses[permission] ?? .unknown))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }

    static let visible: [Permission] = [.inputMonitoring, .accessibility]
}

/// Shown only when one or more required permissions aren't granted.
/// Lists the missing permissions and provides a single-click path into
/// the relevant System Settings pane via `Permission.systemSettingsURL`.
/// The B4/A5 roadmap note about mid-session permission loss motivates
/// this — the user has to recover, and guiding them to the exact pane
/// is a major onboarding / error-recovery win.
struct PermissionAssistantView: View {

    let snapshot: PermissionSnapshot

    var body: some View {
        let missing = snapshot.missingRequired
        if missing.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Permissions needed", bundle: .pulse)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(PulseDesign.amber)
                Text("Pulse can't collect without the following permissions. Grant them in System Settings, then relaunch Pulse.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(missing, id: \.self) { permission in
                    Button {
                        if let url = permission.systemSettingsURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label {
                            Text("Open \(localizedPermissionName(permission)) settings", bundle: .pulse)
                        } icon: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(PulseDesign.amber.opacity(0.10))
            )
        }
    }
}

/// Stable string keys for Pulse's UserDefaults-backed preferences.
/// Centralised here so the Settings panel and any consumer touch the
/// same spelling — mismatches would silently divorce the UI from the
/// stored value.
enum PulsePreferenceKey {
    static let dashboardRefreshIntervalSeconds = "pulse.dashboard.refreshIntervalSeconds"
    static let heatmapDays = "pulse.dashboard.heatmapDays"
    /// F-45 — mirrors `ThresholdAlertsController.screenTimeThresholdKey`
    /// / `noBreakThresholdKey`. Duplicated here so SettingsView can
    /// bind `@AppStorage` without pulling the controller onto the
    /// main-actor graph. `0` means the alert is disabled.
    static let alertScreenTimeSeconds = "pulse.alerts.screenTimeSeconds"
    static let alertNoBreakSeconds = "pulse.alerts.noBreakSeconds"
    /// F-08 / D-K2 — opt-in keycode capture flag. Mirrored verbatim
    /// in `CGEventTapSource` (which reads `UserDefaults` directly on
    /// every `.keyDown` rather than taking a dependency). Default
    /// `false` per Q-06 / docs/05-privacy.md §4.1.
    static let captureKeycodes = "pulse.collection.captureKeycodes"
}

extension UserDefaults {
    /// Seed defaults for every Pulse preference. Called from
    /// `AppDelegate.init` before any consumer reads UserDefaults so the
    /// first run reads sane values instead of `0` / `nil`.
    static func registerPulseDefaults() {
        UserDefaults.standard.register(defaults: [
            PulsePreferenceKey.dashboardRefreshIntervalSeconds: DashboardModel.defaultRefreshIntervalSeconds,
            PulsePreferenceKey.heatmapDays: DashboardModel.defaultHeatmapDays
        ])
    }
}

struct SettingsView: View {

    @AppStorage(PulsePreferenceKey.dashboardRefreshIntervalSeconds)
    private var refreshIntervalSeconds: Double = DashboardModel.defaultRefreshIntervalSeconds
    @AppStorage(PulsePreferenceKey.heatmapDays)
    private var heatmapDays: Int = DashboardModel.defaultHeatmapDays
    @AppStorage(PulseUpdaterDelegate.channelKey)
    private var updateChannel: String = PulseUpdaterDelegate.stableChannel
    @AppStorage(PulsePreferenceKey.alertScreenTimeSeconds)
    private var alertScreenTimeSeconds: Int = 0
    @AppStorage(PulsePreferenceKey.alertNoBreakSeconds)
    private var alertNoBreakSeconds: Int = 0
    @ObservedObject var goalsStore: GoalsStore
    let onOpenPrivacyAudit: () -> Void
    let onPurgeRange: (Date, Date) throws -> RangePurgeResult
    let onCheckForUpdates: () -> Void

    @State private var isPresentingPurgeSheet = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $refreshIntervalSeconds) {
                    Text("1 second",   bundle: .pulse).tag(1.0)
                    Text("5 seconds",  bundle: .pulse).tag(5.0)
                    Text("10 seconds", bundle: .pulse).tag(10.0)
                    Text("30 seconds", bundle: .pulse).tag(30.0)
                } label: {
                    Text("Refresh every", bundle: .pulse)
                }
                Text("How often the Dashboard window re-queries the local database. Reducing the interval uses a tiny bit more CPU; raising it is fine for passive monitoring.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(selection: $heatmapDays) {
                    Text("3 days",  bundle: .pulse).tag(3)
                    Text("7 days",  bundle: .pulse).tag(7)
                    Text("14 days", bundle: .pulse).tag(14)
                    Text("30 days", bundle: .pulse).tag(30)
                } label: {
                    Text("Heatmap window", bundle: .pulse)
                }
                Text("How many past days the weekly heatmap covers. Longer windows make each cell smaller; shorter windows emphasise recent pattern.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Dashboard", bundle: .pulse)
            }

            Section {
                ForEach(GoalPresets.all) { preset in
                    Toggle(isOn: Binding(
                        get: { goalsStore.isEnabled(preset.id) },
                        set: { goalsStore.setEnabled(preset.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(GoalPresetLocalizer.title(for: preset))
                            Text(GoalPresetLocalizer.subtitle(for: preset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Goals", bundle: .pulse)
            } footer: {
                Text("Toggled goals appear at the top of the Dashboard with a progress bar. Nothing here triggers notifications.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { alertScreenTimeSeconds > 0 },
                    set: { alertScreenTimeSeconds = $0 ? 8 * 60 * 60 : 0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warn me when today's screen time exceeds 8 hours", bundle: .pulse)
                        Text("Fires at most once per day as a local notification.", bundle: .pulse)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { alertNoBreakSeconds > 0 },
                    set: { alertNoBreakSeconds = $0 ? 2 * 60 * 60 : 0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nudge me after 2 hours with no break", bundle: .pulse)
                        Text("A short idle segment resets the counter.", bundle: .pulse)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Alerts", bundle: .pulse)
            } footer: {
                Text("Alerts stay local — Pulse never sends anything over the network. macOS may ask for notification permission the first time an alert triggers.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(action: onOpenPrivacyAudit) {
                    Text("Show what Pulse has recorded…", bundle: .pulse)
                }
                Button(role: .destructive) {
                    isPresentingPurgeSheet = true
                } label: {
                    Text("Clear data in a time range…", bundle: .pulse)
                }
            } header: {
                Text("Privacy", bundle: .pulse)
            } footer: {
                Text("Opens a window that lists the raw row counts and the full system-events ledger from the last hour — read live from your local SQLite.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $isPresentingPurgeSheet) {
                RangePurgeSheet(
                    onPurgeRange: onPurgeRange,
                    onDismiss: { isPresentingPurgeSheet = false }
                )
            }

            Section {
                HStack {
                    Text("Build", bundle: .pulse)
                    Spacer()
                    Text(PulsePlatform.buildFingerprint)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle(isOn: Binding(
                    get: { updateChannel == PulseUpdaterDelegate.devChannel },
                    set: { updateChannel = $0 ? PulseUpdaterDelegate.devChannel : PulseUpdaterDelegate.stableChannel }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive development builds", bundle: .pulse)
                        Text("“Check for updates…” will pull from `main` after every merge. Newer features arrive sooner but may be unstable.", bundle: .pulse)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(action: onCheckForUpdates) {
                    Text("Check for updates…", bundle: .pulse)
                }
            } header: {
                Text("About", bundle: .pulse)
            } footer: {
                Text("Update checks are always manual. Pulse never pings GitHub on its own — see docs/05-privacy.md.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
    }
}

// MARK: - Range-purge sheet (F-47)

/// Modal presented from Settings → Privacy. Two date pickers plus
/// a destructive confirmation flow — no keyboard-shortcut "Clear"
/// default action, no silent commit. The sheet stays presented on
/// success so the user sees the "X rows deleted" result and can
/// close on their own terms.
struct RangePurgeSheet: View {

    let onPurgeRange: (Date, Date) throws -> RangePurgeResult
    let onDismiss: () -> Void

    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Date()
    @State private var isConfirming: Bool = false
    @State private var resultMessage: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear a time range", bundle: .pulse)
                .font(PulseDesign.cardTitleFont)

            VStack(alignment: .leading, spacing: 10) {
                DatePicker(
                    selection: $startDate,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("From", bundle: .pulse)
                        .frame(width: 56, alignment: .leading)
                }
                DatePicker(
                    selection: $endDate,
                    in: startDate...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("To", bundle: .pulse)
                        .frame(width: 56, alignment: .leading)
                }
            }

            Text("Every row whose timestamp falls between these moments will be permanently deleted from every data table. An audit note (\"data_purged\") is added to system_events so the Privacy window still shows that a purge occurred. This cannot be undone.", bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let resultMessage {
                Text(verbatim: resultMessage)
                    .font(.footnote)
                    .foregroundStyle(PulseDesign.sage)
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.footnote)
                    .foregroundStyle(PulseDesign.coral)
            }

            HStack {
                Button {
                    onDismiss()
                } label: {
                    Text("Close", bundle: .pulse)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    Text("Clear…", bundle: .pulse)
                }
                .disabled(endDate <= startDate)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .confirmationDialog(
            Text("Delete every event between those moments?", bundle: .pulse),
            isPresented: $isConfirming
        ) {
            Button(role: .destructive) {
                performPurge()
            } label: {
                Text("Delete permanently", bundle: .pulse)
            }
            Button(role: .cancel) {
                isConfirming = false
            } label: {
                Text("Cancel", bundle: .pulse)
            }
        }
    }

    private func performPurge() {
        do {
            let result = try onPurgeRange(startDate, endDate)
            errorMessage = nil
            resultMessage = String.localizedStringWithFormat(
                NSLocalizedString(
                    "Deleted %lld rows across all tables.",
                    bundle: .pulse,
                    comment: "F-47 range-purge success message. %lld is the total rows deleted."
                ),
                Int64(result.deletedRowCount)
            )
        } catch {
            resultMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Daily briefing (A18)

/// Target day for the briefing. Today is only exposed for debug /
/// manual-open paths; the automatic first-wake flow always uses
/// `.yesterday`.
enum BriefingDay {
    case yesterday
    case today

    func startAndEnd(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let todayStart = calendar.startOfDay(for: now)
        switch self {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
            return (todayStart, end)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (start, todayStart)
        }
    }
}

/// Owns the data shown in the daily briefing window. Loaded on demand
/// (`load(for:)`) rather than polled — the window is a one-shot reveal,
/// not a live dashboard.
@MainActor
final class DailyBriefingModel: ObservableObject {

    @Published private(set) var summary: TodaySummary?
    @Published private(set) var longestFocus: FocusSegment?
    @Published private(set) var day: Date?
    @Published private(set) var errorMessage: String?

    private let store: EventStore?

    init(store: EventStore?) {
        self.store = store
    }

    func load(for target: BriefingDay, now: Date = Date()) async {
        guard let store else {
            errorMessage = String(localized: "Database not available.", bundle: .pulse)
            return
        }
        let (start, end) = target.startAndEnd(now: now)
        do {
            let summary = try store.todaySummary(start: start, end: end, capUntil: end)
            let focus = try store.longestFocusSegment(on: start, now: end)
            self.summary = summary
            self.longestFocus = focus
            self.day = start
            self.errorMessage = nil
        } catch {
            self.errorMessage = String.localizedStringWithFormat(
                NSLocalizedString("Failed to load summary: %@", bundle: .pulse, comment: ""),
                error.localizedDescription
            )
        }
    }
}

struct DailyBriefingView: View {

    @ObservedObject var model: DailyBriefingModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.top, .leading, .trailing], 24)
            Divider()
                .overlay(PulseDesign.warmGray(0.14))
                .padding(.top, 18)
            if let summary = model.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MileageHeroCard(
                            distanceMillimeters: summary.totalMouseDistanceMillimeters
                        )
                        BriefingStatRow(summary: summary)
                        if let focus = model.longestFocus {
                            BriefingFocusRow(segment: focus)
                        }
                    }
                    .padding(22)
                }
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(PulseDesign.critical)
                    .padding(24)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
            }
            Spacer(minLength: 0)
            Divider()
                .overlay(PulseDesign.warmGray(0.14))
            HStack {
                Spacer()
                Button {
                    dismissWindow(id: "briefing")
                } label: {
                    Text("Got it", bundle: .pulse)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseDesign.coral)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .background(PulseDesign.surface)
        .task { await model.load(for: .yesterday) }
        .frame(minWidth: 440, minHeight: 460)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Yesterday in Pulse", bundle: .pulse)
                .font(.system(.title2, design: .rounded, weight: .semibold))
            if let day = model.day {
                Text(Self.headerDateFormatter.string(from: day))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMdEEE")
        return formatter
    }()
}

/// Compact two-column stat list used inside the briefing window. Shares
/// its formatters with `SummaryCardsView` so en / zh-Hans output lines
/// up with the main dashboard.
struct BriefingStatRow: View {

    let summary: TodaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Keystrokes", PulseFormat.integer(summary.totalKeyPresses))
            row("Clicks",     PulseFormat.integer(summary.totalMouseClicks))
            row("Scrolls",    PulseFormat.integer(summary.totalScrollTicks))
            row("Active time", PulseFormat.duration(seconds: summary.totalActiveSeconds))
            row("Idle time",   PulseFormat.duration(seconds: summary.totalIdleSeconds))
        }
        .pulseFeaturedCard()
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(titleKey, bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.monospacedDigit())
        }
    }
}

/// One-liner spotlight on the longest focus segment of the day covered
/// by the briefing, styled to echo the Dashboard's `DeepFocusCard`.
struct BriefingFocusRow: View {

    let segment: FocusSegment
    private static let displayNameCache = BundleDisplayNameCache()

    var body: some View {
        let app = Self.displayNameCache.name(for: segment.bundleId)
        let start = Self.clockTime(segment.startedAt)
        let end = Self.clockTime(segment.endedAt)
        VStack(alignment: .leading, spacing: 6) {
            Text("Deep focus today", bundle: .pulse)
                .font(PulseDesign.labelFont)
                .tracking(0.3)
                .foregroundStyle(.secondary)
            Text(PulseFormat.duration(seconds: segment.durationSeconds))
                .font(PulseDesign.heroSecondaryFont)
                .monospacedDigit()
                .foregroundStyle(PulseDesign.coral)
            Text("\(app) · \(start) – \(end)", bundle: .pulse)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(PulseDesign.cardPadding * 0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius)
                .fill(PulseDesign.coral.opacity(0.06))
        )
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}

// MARK: - Privacy audit (A22)

/// Owns the latest snapshot of raw writes the Pulse collector has made
/// in the last hour. Reloaded on user demand — this is a verification
/// tool, not a live dashboard; polling would undermine the "here is
/// exactly what was captured" story.
@MainActor
final class PrivacyAuditModel: ObservableObject {

    @Published private(set) var snapshot: PrivacyAuditSnapshot?
    @Published private(set) var errorMessage: String?

    private let store: EventStore?

    init(store: EventStore?) {
        self.store = store
    }

    /// Rebuilds the snapshot from disk. Safe to call repeatedly; the
    /// read transaction is cheap because raw tables are small.
    func reload(now: Date = Date(), windowSeconds: TimeInterval = 3600) async {
        guard let store else {
            errorMessage = String(localized: "Database not available.", bundle: .pulse)
            return
        }
        do {
            let snap = try await Task.detached {
                try store.buildPrivacyAuditSnapshot(
                    now: now,
                    windowSeconds: windowSeconds
                )
            }.value
            self.snapshot = snap
            self.errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Window that lists the raw per-table row counts and the full
/// `system_events` ledger for the last hour. Lets the user verify the
/// `05-privacy.md` claims in-app, not just in a promise file.
struct PrivacyAuditView: View {

    @ObservedObject var model: PrivacyAuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let snap = model.snapshot {
                countsGrid(snap)
                Divider().overlay(PulseDesign.warmGray(0.14))
                systemEventsSection(snap)
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(PulseDesign.critical)
            } else {
                HStack {
                    ProgressView()
                    Text("Reading the database…", bundle: .pulse)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Divider().overlay(PulseDesign.warmGray(0.14))
            footer
        }
        .padding(22)
        .background(PulseDesign.surface)
        .frame(minWidth: 560, minHeight: 520)
        .task {
            if model.snapshot == nil { await model.reload() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Pulse has recorded", bundle: .pulse)
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text(
                "Every count and row below is read live from your local SQLite — this window is the ground truth, not a summary we maintain separately.",
                bundle: .pulse
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func countsGrid(_ snap: PrivacyAuditSnapshot) -> some View {
        let columns = [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .trailing)
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text(PrivacyAuditView.rangeDescription(snap))
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                countRow(
                    label: Text("Mouse move samples", bundle: .pulse),
                    value: snap.mouseMoveCount
                )
                countRow(
                    label: Text("Mouse click samples", bundle: .pulse),
                    value: snap.mouseClickCount
                )
                countRow(
                    label: Text("Key press samples", bundle: .pulse),
                    value: snap.keyPressCount
                )
                countRow(
                    label: Text("Key codes stored", bundle: .pulse),
                    value: snap.keyCodesRecorded,
                    highlight: snap.keyCodesRecorded == 0 ? PulseDesign.sage : PulseDesign.amber
                )
            }
            HStack {
                Button {
                    Task { await model.reload() }
                } label: {
                    Text("Reload", bundle: .pulse)
                }
                .buttonStyle(.bordered)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [PrivacyAuditView.databaseDirectoryURL()]
                    )
                } label: {
                    Text("Show database in Finder", bundle: .pulse)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func countRow(label: Text, value: Int, highlight: Color? = nil) -> some View {
        label.font(.body)
        Text("\(value)")
            .font(.body.monospacedDigit())
            .foregroundStyle(highlight ?? .primary)
    }

    private func systemEventsSection(_ snap: PrivacyAuditSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System events (latest first)", bundle: .pulse)
                    .font(PulseDesign.cardTitleFont)
                Spacer()
                Text("\(snap.systemEvents.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if snap.systemEvents.isEmpty {
                Text("No events in this window.", bundle: .pulse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(snap.systemEvents.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(PrivacyAuditView.clockTime(row.timestamp))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 68, alignment: .leading)
                                Text(row.category)
                                    .font(.footnote.monospacedDigit())
                                    .frame(width: 144, alignment: .leading)
                                Text(row.payload ?? "—")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 200, maxHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius * 0.75)
                        .fill(PulseDesign.warmGray(0.06))
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "Pulse runs entirely on your Mac. It makes no outbound network calls (the only potential exception is the future update checker, which will be opt-in and point only at GitHub releases).",
                bundle: .pulse
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm:ss")
        return formatter.string(from: date)
    }

    private static func rangeDescription(_ snap: PrivacyAuditSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yyyy-MM-dd HH:mm")
        let start = formatter.string(from: snap.windowStart)
        let end = formatter.string(from: snap.windowEnd)
        let template = NSLocalizedString(
            "privacyAudit.window.template",
            bundle: .pulse,
            value: "Window: %@ → %@",
            comment: "Privacy audit window time range"
        )
        return String(format: template, start, end)
    }

    private static func databaseDirectoryURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Pulse", isDirectory: true)
    }
}

#else

@main
enum PulseApp {
    static func main() {
        print("PulseApp compiled for a non-AppKit platform; app UI is macOS-only.")
    }
}

#endif

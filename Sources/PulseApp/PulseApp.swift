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
                onGenerateReport: { appDelegate.generateWeeklyReport() }
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
                briefingTrigger: appDelegate.briefingTrigger
            )
        }
        .menuBarExtraStyle(.window)

        Window("Pulse Dashboard", id: "dashboard") {
            DashboardView(
                model: appDelegate.dashboardModel,
                healthModel: appDelegate.healthModel
            )
        }
        .defaultSize(width: 720, height: 480)

        Window("Yesterday in Pulse", id: "briefing") {
            DailyBriefingView(model: appDelegate.briefingModel)
        }
        .defaultSize(width: 420, height: 460)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: model.menuBarIconName)
            if anomalyMonitor.hasAnomaly {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
                    .accessibilityLabel(Text("Anomaly", bundle: .module))
            }
        }
        .onReceive(briefingTrigger) { _ in
            openWindow(id: "briefing")
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
    let anomalyMonitor: AnomalyMonitor

    /// Passthrough channel the MenuBarLabel listens on to open the
    /// briefing window. AppDelegate fires this on first-wake-of-day and
    /// when the user explicitly picks "Yesterday's briefing" from the
    /// menu — both paths share the same "have we already shown today?"
    /// gate via UserDefaults.
    let briefingTrigger = PassthroughSubject<Void, Never>()

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
        self.dashboardModel = DashboardModel(
            store: dbResult.database.map { EventStore(database: $0) }
        )
        self.briefingModel = DailyBriefingModel(
            store: dbResult.database.map { EventStore(database: $0) }
        )
        self.anomalyMonitor = AnomalyMonitor(
            store: dbResult.database.map { EventStore(database: $0) }
        )
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
                self?.showBriefingIfDueToday()
                self?.generateWeeklyReportIfDue()
            }
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
                await MainActor.run { NSWorkspace.shared.open(url) }
            } catch {
                #if DEBUG
                print("weekly report failed: \(error)")
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
            NSLocalizedString("Couldn't start the collector: %@", bundle: .module, comment: ""),
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
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentAchievement: LandmarkAchievement?

    private let store: EventStore?
    private var refreshTask: Task<Void, Never>?

    /// Default heatmap window (in days). The user can override via the
    /// Settings panel; the `refresh()` loop re-reads the preference on
    /// every tick so changes take effect on the next poll.
    static let defaultHeatmapDays = 7
    /// Weekly trend chart span — fixed at 7 days for MVP; not user-tunable.
    static let trendDays = 7

    init(store: EventStore?) {
        self.store = store
    }

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
    /// can seed the same value.
    static let defaultRefreshIntervalSeconds: Double = 5.0

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
            errorMessage = String(localized: "Database not available.", bundle: .module)
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
            let focus = try store.longestFocusSegment(on: dayStart, now: now)
            self.summary = summary
            self.heatmapCells = heatmap
            self.heatmapDays = days
            self.trendPoints = trend
            self.longestFocus = focus
            self.lastRefreshAt = now
            self.errorMessage = nil
            updateAchievementIfNeeded(
                distanceMillimeters: summary.totalMouseDistanceMillimeters,
                now: now
            )
        } catch {
            self.errorMessage = String.localizedStringWithFormat(
                NSLocalizedString("Failed to load summary: %@", bundle: .module, comment: ""),
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
    return NSLocalizedString(key, bundle: .module, value: status.rawValue, comment: "")
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
    return NSLocalizedString(key, bundle: .module, value: permission.displayName, comment: "")
}

// MARK: - Views

struct HealthMenuView: View {

    @ObservedObject var model: HealthModel
    let onPause: (TimeInterval) -> Void
    let onResume: () -> Void
    let onShowBriefing: () -> Void
    let onGenerateReport: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pulse", bundle: .module).font(.headline)
                Spacer()
                Text(localizedStatusHeadline(for: model.snapshot), bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Divider()

            CountersView(snapshot: model.snapshot)

            Divider()

            PauseControlsView(
                pause: model.snapshot.pause,
                capturedAt: model.snapshot.capturedAt,
                onPause: onPause,
                onResume: onResume
            )

            Divider()

            PermissionList(snapshot: model.snapshot.permissions)

            PermissionAssistantView(snapshot: model.snapshot.permissions)

            if let message = model.errorMessage {
                Divider()
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Button {
                        openWindow(id: "dashboard")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Open Dashboard", bundle: .module)
                    }
                    Spacer()
                    Button { NSApp.terminate(nil) } label: {
                        Text("Quit Pulse", bundle: .module)
                    }
                    .keyboardShortcut("q")
                }
                HStack(spacing: 16) {
                    Button(action: onShowBriefing) {
                        Text("Yesterday's briefing", bundle: .module)
                            .font(.footnote)
                    }
                    .buttonStyle(.link)
                    Button(action: onGenerateReport) {
                        Text("Generate weekly report", bundle: .module)
                            .font(.footnote)
                    }
                    .buttonStyle(.link)
                    Spacer()
                }
            }
        }
        .padding(14)
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
                        Text("Paused", bundle: .module)
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .font(.footnote.bold())
                    .foregroundStyle(.orange)
                    Text("Resumes \(PulseFormat.countdown(from: capturedAt, to: resumesAt))", bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onResume) {
                    Text("Resume now", bundle: .module)
                }
            }
        } else {
            Menu {
                Button { onPause(15 * 60) } label: { Text("15 minutes", bundle: .module) }
                Button { onPause(30 * 60) } label: { Text("30 minutes", bundle: .module) }
                Button { onPause(60 * 60) } label: { Text("1 hour",     bundle: .module) }
            } label: {
                Label {
                    Text("Pause collection…", bundle: .module)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                DashboardPermissionBanner(permissions: healthModel.snapshot.permissions)
                if let achievement = model.recentAchievement {
                    MilestoneAchievementBanner(
                        achievement: achievement,
                        onDismiss: { model.dismissAchievement() }
                    )
                }
                if let summary = model.summary {
                    MileageHeroCard(distanceMillimeters: summary.totalMouseDistanceMillimeters)
                    LandmarkProgressPanel(distanceMillimeters: summary.totalMouseDistanceMillimeters)
                    SummaryCardsView(summary: summary, trend: model.trendPoints)
                    WeekTrendChart(points: model.trendPoints)
                    WeekHourlyHeatmap(cells: model.heatmapCells, days: model.heatmapDays)
                    DeepFocusCard(segment: model.longestFocus)
                    AppRankingChart(rows: summary.topApps)
                    DiagnosticsCard(snapshot: healthModel.snapshot)
                } else if model.errorMessage != nil {
                    Text(model.errorMessage ?? "")
                        .foregroundStyle(.red)
                } else {
                    ProgressView {
                        Text("Loading today's data…", bundle: .module)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 400)
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
                        Text("Refresh", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today", bundle: .module)
                .font(.largeTitle.bold())
            if let last = model.lastRefreshAt {
                Text("Updated \(PulseFormat.ago(from: last, to: Date()))", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Pulse isn't collecting right now", bundle: .module)
                        .font(.headline)
                }
                Text("Grant the permissions below in System Settings, then relaunch Pulse. Until then the numbers on this page won't update.", bundle: .module)
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
                                Text("Open \(localizedPermissionName(permission))", bundle: .module)
                            } icon: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Milestone reached", bundle: .module)
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                Text("Today's mileage just hit \(landmarkName) — \(landmarkDistance).", bundle: .module)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You've moved \(movedSoFar) so far today.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss", bundle: .module))
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
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

        VStack(alignment: .leading, spacing: 10) {
            Text("Mouse mileage today", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(PulseFormat.distance(millimeters: distanceMillimeters))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(PulseFormat.landmarkComparisonSentence(for: comparison))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Landmarks", bundle: .module)
                .font(.headline)
            VStack(spacing: 8) {
                ForEach(rows, id: \.0.key) { row in
                    LandmarkProgressRow(landmark: row.0, ratio: row.1)
                }
            }
        }
    }
}

struct LandmarkProgressRow: View {

    let landmark: Landmark
    let ratio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(PulseFormat.localizedLandmarkName(for: landmark))
                    .font(.footnote)
                Spacer()
                Text(valueText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.85), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(1, max(0, ratio)))
                }
            }
            .frame(height: 6)
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
        let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
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
                series: trend.map { Double($0.scrollTicks) }
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
                Text(titleKey, bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let delta = deltaVsYesterday {
                    DeltaChip(deltaFraction: delta)
                }
            }
            Text(value)
                .font(.title2.monospacedDigit())
            if let narrativeSubtitle {
                Text(narrativeSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if showSparkline {
                Sparkline(points: series)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    .frame(height: 20)
                    .opacity(0.85)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

/// Tiny ±N% chip with an up / down arrow. Used next to metric titles to
/// signal "vs yesterday" movement at a glance.
struct DeltaChip: View {

    let deltaFraction: Double

    var body: some View {
        let pct = Int((deltaFraction * 100).rounded())
        let isUp = deltaFraction >= 0
        HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.bold())
            Text("\(abs(pct))%")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(isUp ? Color.green : Color.orange)
    }
}

/// Line-only sparkline that stretches to fill its container. Uses raw
/// `Path` (not SwiftUI Charts) because Chart has more overhead than
/// warranted for a 40×20 tile.
struct Sparkline: Shape {

    let points: [Double]

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
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly trend", bundle: .module)
                .font(.headline)
            if points.allSatisfy({ $0.totalEvents == 0 }) {
                Text("No rolled-up activity yet. Check back once hourly roll-ups have run.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Events", point.totalEvents)
                    )
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Events", point.totalEvents)
                    )
                    .symbolSize(40)
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(shortDay(date))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            headlineText.font(.headline)
            content
            insightFooter
        }
    }

    @ViewBuilder
    private var headlineText: some View {
        switch days {
        case ..<7:   Text("Recent heatmap",   bundle: .module)
        case 7:      Text("Weekly heatmap",   bundle: .module)
        case 8...14: Text("Two-week heatmap", bundle: .module)
        default:     Text("\(days)-day heatmap", bundle: .module)
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
                Text("Peak at \(hourString)", bundle: .module)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(descriptorKey, bundle: .module)
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

    /// Maps intensity ∈ [0, 1] onto a cool → warm color ramp so the heatmap
    /// shows hotter peaks in orange and quieter hours in a low-saturation
    /// green. `intensity = 0` still renders a visible cell (min saturation)
    /// so empty hours stay distinguishable from missing-data regions.
    private static func heatColor(intensity: Double) -> Color {
        let clamped = max(0, min(1, intensity))
        let hue = 0.35 - 0.30 * clamped       // 0.35 (green) → 0.05 (orange-red)
        let saturation = 0.15 + 0.70 * clamped
        let brightness = 0.55 + 0.40 * clamped
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    @ViewBuilder
    private func dayLabel(for dayOffset: Int) -> some View {
        switch dayOffset {
        case 0:
            Text("Today", bundle: .module)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case 1:
            Text("Yday", bundle: .module)
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

/// Foot-of-Dashboard diagnostics panel (F-49 "自检状态页" deepening).
/// Surfaces the data already carried in `HealthSnapshot` so users can
/// answer "Is Pulse actually working?" without opening the menu bar.
/// Highlights a prominent warning row if `isSilentlyFailing` triggers —
/// the most actionable signal after permissions.
struct DiagnosticsCard: View {

    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics", bundle: .module)
                .font(.headline)

            if snapshot.isSilentlyFailing {
                Label {
                    Text("No writes in the last minute — Pulse may have lost permission or stopped.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(8)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            metricRow(labelKey: "Last data point",
                      value: snapshot.lastWriteAt.map { PulseFormat.ago(from: $0, to: snapshot.capturedAt) }
                        ?? String(localized: "never", bundle: .module))
            metricRow(labelKey: "Last rollup",
                      value: mostRecentRollup.map { PulseFormat.ago(from: $0, to: snapshot.capturedAt) }
                        ?? String(localized: "never", bundle: .module))
            metricRow(labelKey: "Database size",
                      value: snapshot.databaseFileSizeBytes.map(PulseFormat.bytes) ?? "–")
            metricRow(labelKey: "Total ingest batches",
                      value: PulseFormat.integer(snapshot.writer.totalFlushes))

            if let error = snapshot.writer.lastErrorDescription,
               let errorAt = snapshot.writer.lastErrorAt {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text("Last writer error", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote.bold())
                    .foregroundStyle(.orange)
                    Text("\(PulseFormat.ago(from: errorAt, to: snapshot.capturedAt)): \(error)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func metricRow(labelKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(labelKey, bundle: .module)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Deep focus today", bundle: .module)
                .font(.headline)
            if let segment {
                filled(segment)
            } else {
                empty
            }
        }
    }

    @ViewBuilder
    private func filled(_ segment: FocusSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PulseFormat.duration(seconds: segment.durationSeconds))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            let app = Self.displayNameCache.name(for: segment.bundleId)
            let start = Self.clockTime(segment.startedAt)
            let end = Self.clockTime(segment.endedAt)
            Text("\(app) · \(start) – \(end)", bundle: .module)
                .font(.body)
                .foregroundStyle(.primary)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var empty: some View {
        Text("Still warming up — your longest focus streak shows up once you've spent 20+ minutes in one app without going idle.", bundle: .module)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}

struct AppRankingChart: View {

    let rows: [AppUsageRow]

    private static let displayNameCache = BundleDisplayNameCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top apps", bundle: .module)
                .font(.headline)
            if rows.isEmpty {
                Text("No app activity recorded yet today.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Seconds", row.secondsUsed),
                        y: .value("App", displayName(for: row.bundleId))
                    )
                    .annotation(position: .trailing) {
                        Text(PulseFormat.duration(seconds: row.secondsUsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: max(120, CGFloat(rows.count) * 32))
            }
        }
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
                rowText(labelKey: "Last write", value: String(localized: "never", bundle: .module))
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
            Text(labelKey, bundle: .module)
            Spacer()
            Text(PulseFormat.integer(value))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func rowText(labelKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(labelKey, bundle: .module)
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
            ForEach(Permission.allCases, id: \.self) { permission in
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
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Permissions needed", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote.bold())
                .foregroundStyle(.orange)
                Text("Pulse can't collect without the following permissions. Grant them in System Settings, then relaunch Pulse.", bundle: .module)
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
                            Text("Open \(localizedPermissionName(permission)) settings", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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

    var body: some View {
        Form {
            Section {
                Picker(selection: $refreshIntervalSeconds) {
                    Text("1 second",   bundle: .module).tag(1.0)
                    Text("5 seconds",  bundle: .module).tag(5.0)
                    Text("10 seconds", bundle: .module).tag(10.0)
                    Text("30 seconds", bundle: .module).tag(30.0)
                } label: {
                    Text("Refresh every", bundle: .module)
                }
                Text("How often the Dashboard window re-queries the local database. Reducing the interval uses a tiny bit more CPU; raising it is fine for passive monitoring.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(selection: $heatmapDays) {
                    Text("3 days",  bundle: .module).tag(3)
                    Text("7 days",  bundle: .module).tag(7)
                    Text("14 days", bundle: .module).tag(14)
                    Text("30 days", bundle: .module).tag(30)
                } label: {
                    Text("Heatmap window", bundle: .module)
                }
                Text("How many past days the weekly heatmap covers. Longer windows make each cell smaller; shorter windows emphasise recent pattern.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Dashboard", bundle: .module)
            }

            Section {
                HStack {
                    Text("Build", bundle: .module)
                    Spacer()
                    Text(PulsePlatform.buildFingerprint)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("About", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
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
            errorMessage = String(localized: "Database not available.", bundle: .module)
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
                NSLocalizedString("Failed to load summary: %@", bundle: .module, comment: ""),
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
                .padding([.top, .leading, .trailing], 20)
            Divider().padding(.top, 16)
            if let summary = model.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MileageHeroCard(
                            distanceMillimeters: summary.totalMouseDistanceMillimeters
                        )
                        BriefingStatRow(summary: summary)
                        if let focus = model.longestFocus {
                            BriefingFocusRow(segment: focus)
                        }
                    }
                    .padding(20)
                }
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button {
                    dismissWindow(id: "briefing")
                } label: {
                    Text("Got it", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .task { await model.load(for: .yesterday) }
        .frame(minWidth: 400, minHeight: 420)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Yesterday in Pulse", bundle: .module)
                .font(.title2.bold())
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
        VStack(alignment: .leading, spacing: 8) {
            row("Keystrokes", PulseFormat.integer(summary.totalKeyPresses))
            row("Clicks",     PulseFormat.integer(summary.totalMouseClicks))
            row("Scrolls",    PulseFormat.integer(summary.totalScrollTicks))
            row("Active time", PulseFormat.duration(seconds: summary.totalActiveSeconds))
            row("Idle time",   PulseFormat.duration(seconds: summary.totalIdleSeconds))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(titleKey, bundle: .module)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Deep focus today", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(PulseFormat.duration(seconds: segment.durationSeconds))
                .font(.title3.monospacedDigit().bold())
            Text("\(app) · \(start) – \(end)", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
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

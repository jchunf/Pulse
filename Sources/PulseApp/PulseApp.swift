import Foundation
import PulseCore
import PulsePlatform

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Charts

@main
struct PulseApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HealthMenuView(model: appDelegate.healthModel)
        } label: {
            // Use a different SF Symbol when collection is paused or
            // permissions are missing so the user can read state at a
            // glance from the menu bar.
            Image(systemName: appDelegate.healthModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Window("Pulse Dashboard", id: "dashboard") {
            DashboardView(model: appDelegate.dashboardModel)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsPlaceholder()
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

    private let database: PulseDatabase?
    private let runtime: CollectorRuntime?
    private let systemEventEmitter: SystemEventEmitter
    private let appWatcher: NSWorkspaceAppWatcher
    private let lidPowerObserver: LidPowerObserver
    private let titleObserver: AccessibilityTitleObserver
    private var pollTask: Task<Void, Never>?

    override init() {
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
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { [weak self] in await self?.bootCollector() }
        startHealthPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        systemEventEmitter.stop()
        appWatcher.stop()
        lidPowerObserver.stop()
        titleObserver.stop()
        Task { [runtime] in await runtime?.stop() }
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
        self.errorMessage = "Couldn't start the collector: \(error.localizedDescription)"
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
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var errorMessage: String?

    private let store: EventStore?
    private var refreshTask: Task<Void, Never>?

    init(store: EventStore?) {
        self.store = store
    }

    /// Begin polling. Idempotent — calling twice is a no-op.
    func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard let store else {
            errorMessage = "Database not available."
            return
        }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        do {
            let summary = try store.todaySummary(start: dayStart, end: dayEnd, capUntil: now)
            self.summary = summary
            self.lastRefreshAt = now
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Failed to load summary: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

struct HealthMenuView: View {

    @ObservedObject var model: HealthModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pulse").font(.headline)
                Spacer()
                Text(model.snapshot.statusHeadline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Divider()

            CountersView(snapshot: model.snapshot)

            Divider()

            PermissionList(snapshot: model.snapshot.permissions)

            if let message = model.errorMessage {
                Divider()
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit Pulse") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct DashboardView: View {

    @ObservedObject var model: DashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let summary = model.summary {
                    SummaryCardsView(summary: summary)
                    AppRankingChart(rows: summary.topApps)
                } else if model.errorMessage != nil {
                    Text(model.errorMessage ?? "")
                        .foregroundStyle(.red)
                } else {
                    ProgressView("Loading today's data…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.largeTitle.bold())
            if let last = model.lastRefreshAt {
                Text("Updated \(formatRelative(last))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatRelative(_ instant: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(instant))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3_600)h ago"
    }
}

struct SummaryCardsView: View {

    let summary: TodaySummary

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            metric(title: "Distance", value: formatMeters(summary.totalMouseDistanceMillimeters))
            metric(title: "Clicks", value: format(summary.totalMouseClicks))
            metric(title: "Keystrokes", value: format(summary.totalKeyPresses))
            metric(title: "Active time", value: formatDuration(summary.totalActiveSeconds))
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatMeters(_ mm: Double) -> String {
        let meters = mm / 1_000.0
        if meters < 1 { return String(format: "%.0f mm", mm) }
        if meters < 1_000 { return String(format: "%.1f m", meters) }
        return String(format: "%.2f km", meters / 1_000.0)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return "\(hours)h \(remMinutes)m"
    }
}

struct AppRankingChart: View {

    let rows: [AppUsageRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top apps")
                .font(.headline)
            if rows.isEmpty {
                Text("No app activity recorded yet today.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Seconds", row.secondsUsed),
                        y: .value("App", row.bundleId)
                    )
                    .annotation(position: .trailing) {
                        Text(formatDuration(row.secondsUsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: max(120, CGFloat(rows.count) * 32))
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }
}

struct CountersView: View {

    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(label: "Mouse moves (raw)",  value: snapshot.l0Counts.mouseMoves)
            row(label: "Mouse clicks (raw)", value: snapshot.l0Counts.mouseClicks)
            row(label: "Key events (raw)",   value: snapshot.l0Counts.keyEvents)
            row(label: "Total flushes",      value: snapshot.writer.totalFlushes)
            if let last = snapshot.lastWriteAt {
                rowText(label: "Last write", value: relative(last, from: snapshot.capturedAt))
            } else {
                rowText(label: "Last write", value: "never")
            }
            if let bytes = snapshot.databaseFileSizeBytes {
                rowText(label: "DB size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func row(label: String, value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func rowText(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func relative(_ instant: Date, from now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(instant))
        if seconds < 1 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3_600)h ago"
    }
}

struct PermissionList: View {

    let snapshot: PermissionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Permission.allCases, id: \.self) { permission in
                HStack {
                    Text(permission.rawValue)
                    Spacer()
                    Text((snapshot.statuses[permission] ?? .unknown).rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }
}

struct SettingsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulse Preferences")
                .font(.title2)
            Text("Detailed preferences arrive in a later PR. For now, this panel is a placeholder so the Settings scene is wired.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480, height: 280)
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

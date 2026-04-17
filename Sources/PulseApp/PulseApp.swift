import Foundation
import PulseCore
import PulsePlatform

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

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

    private let database: PulseDatabase?
    private let runtime: CollectorRuntime?
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

        self.healthModel = HealthModel(
            permissionService: permissions,
            errorMessage: dbResult.errorMessage
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
        Task { [runtime] in await runtime?.stop() }
    }

    // MARK: - Private

    private func bootCollector() async {
        guard let runtime else { return }
        do {
            try await runtime.start()
        } catch {
            await MainActor.run { healthModel.recordStartupError(error) }
        }
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

// MARK: - Views

struct HealthMenuView: View {

    @ObservedObject var model: HealthModel

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
                Button("Quit Pulse") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 360)
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

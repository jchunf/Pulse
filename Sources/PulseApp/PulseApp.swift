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
            MenuBarContent()
                .environmentObject(appDelegate.permissionSnapshotProvider)
        } label: {
            Image(systemName: "waveform.path.ecg")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholder()
        }
    }
}

/// Empty app-delegate placeholder so we can centralize startup wiring when
/// B2 adds collectors. Also hides Dock icon at launch (LSUIElement behavior).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionSnapshotProvider = PermissionSnapshotProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Thin wrapper that the menu bar view observes. Refreshes on appearance so
/// the user sees permission changes without restarting the app.
final class PermissionSnapshotProvider: ObservableObject {
    @Published var snapshot: PermissionSnapshot

    private let service: PermissionService

    init(service: PermissionService = PulsePlatform.permissionService()) {
        self.service = service
        self.snapshot = PermissionSnapshot(statuses: [:], capturedAt: Date())
        self.snapshot = service.snapshot(at: Date())
    }

    @MainActor
    func refresh() {
        self.snapshot = service.snapshot(at: Date())
    }
}

// MARK: - Views

/// Placeholder menu bar content — intentionally minimal for B1. Visualizes
/// only permission state so the user knows the plumbing works. Dashboard
/// content (F-02, F-03, F-07) lands in phase A.
struct MenuBarContent: View {

    @EnvironmentObject private var provider: PermissionSnapshotProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulse")
                .font(.headline)
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            PermissionList(snapshot: provider.snapshot)
            Divider()
            Button("Quit Pulse") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            provider.refresh()
        }
    }

    private var statusLine: String {
        if provider.snapshot.isAllRequiredGranted {
            return "Collecting your pulse — welcome."
        } else {
            return "Waiting for permissions. Open settings to continue."
        }
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

/// Linux / non-AppKit fallback so `swift build` succeeds on CI smoke runners
/// (we only depend on `swift build` working enough to compile the package
/// graph; actual execution happens on macOS).
@main
enum PulseApp {
    static func main() {
        print("PulseApp compiled for a non-AppKit platform; app UI is macOS-only.")
    }
}

#endif

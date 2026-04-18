import Foundation
import PulseCore
import Combine

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Linear walk-through the user sees the very first time they open
/// `Pulse.app`. The flow is the spec from
/// `docs/06-onboarding-permissions.md` distilled to four screens:
/// welcome → privacy pledge → guided permission grants → ready.
///
/// Onboarding is opt-out: the moment all required permissions are
/// granted (whether through this flow or before — e.g. a returning
/// user who already accepted them) the model marks the gate done so
/// the window doesn't reopen on the next launch.
@MainActor
final class OnboardingModel: ObservableObject {

    enum Step: Int, CaseIterable {
        case welcome
        case privacyPledge
        case grantInputMonitoring
        case grantAccessibility
        case ready

        var index: Int { rawValue }
        static var total: Int { Self.allCases.count }
    }

    @Published var step: Step = .welcome
    @Published var pledgeAccepted: Bool = false
    @Published private(set) var permissions: PermissionSnapshot

    private let permissionService: PermissionService
    private var pollTask: Task<Void, Never>?

    /// UserDefaults key flagging whether onboarding has run on this Mac.
    /// Carries the ISO-8601 completion timestamp (string) so a future
    /// version-bump path can re-show onboarding for breaking changes.
    static let completedKey = "pulse.onboarding.completedAt"

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
        self.permissions = permissionService.snapshot(at: Date())
    }

    static func hasCompleted() -> Bool {
        UserDefaults.standard.string(forKey: completedKey) != nil
    }

    static func markCompleted(now: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        UserDefaults.standard.set(formatter.string(from: now), forKey: completedKey)
    }

    func startPollingPermissions() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self else { return }
                    self.permissions = self.permissionService.snapshot(at: Date())
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPollingPermissions() {
        pollTask?.cancel()
        pollTask = nil
    }

    func canAdvance(from step: Step) -> Bool {
        switch step {
        case .welcome: return true
        case .privacyPledge: return pledgeAccepted
        case .grantInputMonitoring:
            return permissions.statuses[.inputMonitoring] == .granted
        case .grantAccessibility:
            return permissions.statuses[.accessibility] == .granted
        case .ready: return true
        }
    }

    func advance() {
        guard canAdvance(from: step) else { return }
        let next = step.index + 1
        if next < Step.total, let nextStep = Step(rawValue: next) {
            step = nextStep
        }
    }

    func back() {
        let prev = step.index - 1
        if prev >= 0, let prevStep = Step(rawValue: prev) {
            step = prevStep
        }
    }

    func openSystemSettings(for permission: Permission) {
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - View

struct OnboardingView: View {

    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(PulseDesign.surface)
        .frame(minWidth: 600, minHeight: 520)
        .task { model.startPollingPermissions() }
        .onDisappear { model.stopPollingPermissions() }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.index <= model.step.index ? PulseDesign.coral : PulseDesign.warmGray(0.18))
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:               WelcomeStep()
        case .privacyPledge:         PledgeStep(accepted: $model.pledgeAccepted)
        case .grantInputMonitoring:
            PermissionStep(
                permission: .inputMonitoring,
                snapshot: model.permissions,
                onOpenSettings: { model.openSystemSettings(for: .inputMonitoring) }
            )
        case .grantAccessibility:
            PermissionStep(
                permission: .accessibility,
                snapshot: model.permissions,
                onOpenSettings: { model.openSystemSettings(for: .accessibility) }
            )
        case .ready:                 ReadyStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                Button {
                    model.back()
                } label: {
                    Text("Back", bundle: .module)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if model.step == .ready {
                Button {
                    OnboardingModel.markCompleted()
                    onFinish()
                } label: {
                    Text("Open Pulse", bundle: .module)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseDesign.coral)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    model.advance()
                } label: {
                    Text("Continue", bundle: .module)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseDesign.coral)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdvance(from: model.step))
            }
        }
        .padding(22)
        .background(PulseDesign.warmGray(0.04))
    }
}

// MARK: - Step views

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            // Concentric-circle pulse glyph to echo the app name in motion.
            ZStack {
                Circle()
                    .fill(PulseDesign.coral.opacity(0.10))
                    .frame(width: 96, height: 96)
                    .pulseHeartbeat(amplitude: .hero)
                Circle()
                    .fill(PulseDesign.coral.opacity(0.18))
                    .frame(width: 58, height: 58)
                    .pulseHeartbeat(amplitude: .hero)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(PulseDesign.coral)
            }
            .padding(.bottom, 4)
            Text("Welcome to Pulse", bundle: .module)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text("A local-first dashboard for the way you actually use your Mac. Pulse turns the noisy stream of clicks, key presses, scrolls and app switches into a daily story you can read in 30 seconds.", bundle: .module)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

private struct PledgeStep: View {

    @Binding var accepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Privacy promises", bundle: .module)
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text("Before we ask for any permissions, here is what Pulse will and will not do — read it first.", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                pledge("All raw data stays inside ~/Library/Application Support/Pulse/. Nothing is ever uploaded.")
                pledge("No keystroke contents — only press counts. By default the key code is not stored either.")
                pledge("No clipboard, no screen recording, no microphone, no camera, ever.")
                pledge("Window titles are SHA-256 hashed before being persisted.")
                pledge("Pulse makes zero outbound network calls (a future opt-in update checker is the only exception, and it would only hit GitHub Releases).")
            }
            .padding(.vertical, 4)
            Toggle(isOn: $accepted) {
                Text("I've read these promises and want to continue.", bundle: .module)
                    .font(.body)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 6)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pledge(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(PulseDesign.sage)
            Text(key, bundle: .module)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionStep: View {

    let permission: Permission
    let snapshot: PermissionSnapshot
    let onOpenSettings: () -> Void

    private var status: PermissionStatus {
        snapshot.statuses[permission] ?? .unknown
    }

    private var headline: LocalizedStringKey {
        switch permission {
        case .inputMonitoring: return "Grant Input Monitoring"
        case .accessibility:   return "Grant Accessibility"
        default:               return "Grant permission"
        }
    }

    private var body1: LocalizedStringKey {
        switch permission {
        case .inputMonitoring:
            return "Pulse uses Input Monitoring to count clicks, key presses and scroll ticks system-wide. **It only counts events — it never records what you type.** macOS will quit and relaunch Pulse the moment you flip the switch; that's normal."
        case .accessibility:
            return "Pulse uses Accessibility to read which app is in the foreground and (optionally) the title of the active window. Window titles are hashed before being stored."
        default:
            return "This permission is required for Pulse to function."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(headline, bundle: .module)
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text(body1, bundle: .module)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            instructionsBox

            HStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text("Open System Settings", bundle: .module)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseDesign.coral)
                statusChip
                Spacer()
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var instructionsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            instructionRow(number: 1, text: "Click **Open System Settings** below.")
            instructionRow(number: 2, text: "Find **Pulse** in the list.")
            instructionRow(number: 3, text: "Toggle the switch on. macOS may ask for your password.")
            if permission == .inputMonitoring {
                instructionRow(number: 4, text: "macOS quits Pulse to apply the change. Reopen Pulse after — onboarding will resume here.")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PulseDesign.warmGray(0.05))
        )
    }

    private func instructionRow(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.body.monospacedDigit())
                .foregroundStyle(PulseDesign.coral)
                .frame(width: 18, alignment: .leading)
            Text(text, bundle: .module)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch status {
        case .granted:
            Label {
                Text("Granted", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(PulseDesign.sage)
        case .denied, .notDetermined, .unknown:
            Label {
                Text("Waiting…", bundle: .module)
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(PulseDesign.amber)
        }
    }
}

private struct ReadyStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(PulseDesign.sage.opacity(0.10))
                    .frame(width: 96, height: 96)
                    .pulseHeartbeat(amplitude: .hero)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(PulseDesign.sage)
            }
            .padding(.bottom, 4)
            Text("You're set", bundle: .module)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text("Pulse is now collecting your activity locally. Open the menu bar icon any time to pause, peek at today's numbers, or read the privacy ledger.", bundle: .module)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

#endif

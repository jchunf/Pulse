#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore
import UserNotifications

/// F-45 — delivers `ThresholdAlertKind`s as local notifications via
/// `UNUserNotificationCenter`, and persists per-day "already fired"
/// memory so a single threshold crossing never re-prompts until the
/// next calendar day.
///
/// The evaluator lives in PulseCore; this type is the thin
/// AppKit-side wiring: it pulls settings out of `UserDefaults`,
/// requests `.alert + .sound` authorisation lazily the first time
/// the user enables an alert, posts the notifications, and writes
/// back the fired-kind memory.
@MainActor
final class ThresholdAlertsController {

    private let center: UNUserNotificationCenter
    private let calendar: Calendar
    private let defaults: UserDefaults

    // MARK: - UserDefaults keys

    /// Day string ("YYYY-MM-DD") the memory below belongs to. When the
    /// current day doesn't match, memory is wiped — so alerts get one
    /// shot per kind per calendar day.
    static let firedDayKey = "pulse.alerts.firedDay"
    static let firedKindsKey = "pulse.alerts.firedKinds"

    /// User-tunable thresholds. `0` or missing → alert disabled.
    static let screenTimeThresholdKey = "pulse.alerts.screenTimeSeconds"
    static let noBreakThresholdKey = "pulse.alerts.noBreakSeconds"

    init(
        center: UNUserNotificationCenter = .current(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.calendar = calendar
        self.defaults = defaults
    }

    /// Read the user's thresholds out of `UserDefaults`. A stored
    /// value of `0` counts as "disabled" so the Settings toggle can
    /// encode "off" as a zero threshold without losing the last-
    /// chosen non-zero value.
    var currentSettings: ThresholdAlertSettings {
        let screenRaw = defaults.integer(forKey: Self.screenTimeThresholdKey)
        let breakRaw = defaults.integer(forKey: Self.noBreakThresholdKey)
        return ThresholdAlertSettings(
            screenTimeSecondsThreshold: screenRaw > 0 ? screenRaw : nil,
            noBreakSecondsThreshold:    breakRaw > 0 ? breakRaw : nil
        )
    }

    /// Evaluate + deliver. Called from the Dashboard's refresh loop
    /// every tick the metrics are fresh. Cheap when both alerts are
    /// disabled (the evaluator short-circuits on `nil` thresholds).
    func evaluateAndFire(metrics: ThresholdAlertMetrics, now: Date) {
        let memory = loadMemory(for: now)
        let alerts = ThresholdAlertEvaluator.evaluate(
            settings: currentSettings,
            metrics: metrics,
            memory: memory
        )
        guard !alerts.isEmpty else { return }

        requestAuthorizationIfNeeded()
        for alert in alerts {
            deliver(alert)
            recordFired(alert, for: now)
        }
    }

    // MARK: - Private

    private var authorizationRequested = false

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliver(_ alert: ThresholdAlertKind) {
        let content = UNMutableNotificationContent()
        switch alert {
        case let .screenTimeExceeded(threshold, actual):
            content.title = String(
                localized: "Screen time reminder", bundle: .pulse
            )
            content.body = String.localizedStringWithFormat(
                String(localized: "You've been active for %@ today (threshold: %@).",
                       bundle: .pulse),
                PulseFormat.duration(seconds: actual),
                PulseFormat.duration(seconds: threshold)
            )
        case let .noBreakSince(threshold, actual):
            content.title = String(
                localized: "Time for a break?", bundle: .pulse
            )
            content.body = String.localizedStringWithFormat(
                String(localized: "You've been active for %@ without a break (threshold: %@).",
                       bundle: .pulse),
                PulseFormat.duration(seconds: actual),
                PulseFormat.duration(seconds: threshold)
            )
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "pulse.alert.\(alert.identifier).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    private func dayString(for date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private func loadMemory(for now: Date) -> ThresholdAlertMemory {
        let today = dayString(for: now)
        let storedDay = defaults.string(forKey: Self.firedDayKey)
        guard storedDay == today else {
            // New day — stale memory rolled over.
            defaults.set(today, forKey: Self.firedDayKey)
            defaults.set([] as [String], forKey: Self.firedKindsKey)
            return ThresholdAlertMemory()
        }
        let stored = defaults.stringArray(forKey: Self.firedKindsKey) ?? []
        return ThresholdAlertMemory(firedKinds: Set(stored))
    }

    private func recordFired(_ alert: ThresholdAlertKind, for now: Date) {
        let today = dayString(for: now)
        defaults.set(today, forKey: Self.firedDayKey)
        var current = defaults.stringArray(forKey: Self.firedKindsKey) ?? []
        if !current.contains(alert.identifier) {
            current.append(alert.identifier)
            defaults.set(current, forKey: Self.firedKindsKey)
        }
    }
}
#endif

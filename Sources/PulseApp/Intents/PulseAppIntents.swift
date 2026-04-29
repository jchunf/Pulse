import AppIntents
import Foundation
import PulseCore

// MARK: - F-44 — App Intents (macOS Shortcuts integration)
//
// Three intents expose the most-asked questions from the Dashboard to
// macOS Shortcuts:
//
//   1. `GetAppUsageTodayIntent` — "how long did I use Xcode today?"
//   2. `GetTodayKeystrokesIntent` — "how many keys did I press today?"
//   3. `GetTodayMouseDistanceIntent` — "how far did my cursor travel
//      today?" (in metres, the dashboard hero unit)
//
// Each intent runs in the GUI app process when invoked from Shortcuts,
// reads the same SQLite file the dashboard reads, and returns a typed
// result Shortcuts can chain into other steps. No new collectors, no
// new permissions — F-44 is a pure surface over already-collected,
// already-disclosed local aggregates. The privacy posture matches the
// rest of Pulse: data never leaves the device, and the intent only
// answers questions the user could already answer by opening the app.
//
// Localisation: titles, descriptions, parameter labels, and short
// titles are routed through `Localizable.xcstrings` via
// `bundle: .atURL(Bundle.pulse.bundleURL)`. Spoken / shown dialog
// after the action completes stays English (the spoken response is
// a power-user surface and the format strings carry runtime values
// — adding format-string entries doubles the catalog churn for low
// per-user value).
//
// Siri trigger phrases (`AppShortcut.phrases`) also stay English; they
// drive English-only Siri voice and Spotlight matching. Full Siri
// localisation can come as a follow-up if there's user demand.

struct GetAppUsageTodayIntent: AppIntent {

    static let title = LocalizedStringResource(
        "How long did I use…",
        bundle: .atURL(Bundle.pulse.bundleURL)
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "Returns the seconds you've spent in a given app today, read from Pulse's local data only.",
            bundle: .atURL(Bundle.pulse.bundleURL)
        )
    )
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: LocalizedStringResource(
            "Bundle ID",
            bundle: .atURL(Bundle.pulse.bundleURL)
        ),
        description: LocalizedStringResource(
            "The bundle identifier of the app (e.g. com.apple.dt.Xcode for Xcode).",
            bundle: .atURL(Bundle.pulse.bundleURL)
        )
    )
    var bundleId: String

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let store = try PulseIntentBackend.store()
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return .result(value: 0, dialog: "0 seconds")
        }
        let seconds = try store.appUsageSeconds(
            bundleId: bundleId,
            start: dayStart,
            end: dayEnd,
            capUntil: now
        )
        let minutes = max(0, seconds / 60)
        return .result(value: seconds, dialog: "\(minutes) min in \(bundleId) today")
    }
}

struct GetTodayKeystrokesIntent: AppIntent {

    static let title = LocalizedStringResource(
        "Keystrokes today",
        bundle: .atURL(Bundle.pulse.bundleURL)
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "Total key presses Pulse recorded for you today.",
            bundle: .atURL(Bundle.pulse.bundleURL)
        )
    )
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let store = try PulseIntentBackend.store()
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return .result(value: 0, dialog: "0")
        }
        let summary = try store.todaySummary(start: dayStart, end: dayEnd, capUntil: now)
        return .result(
            value: summary.totalKeyPresses,
            dialog: "\(summary.totalKeyPresses) keystrokes today"
        )
    }
}

struct GetTodayMouseDistanceIntent: AppIntent {

    static let title = LocalizedStringResource(
        "Mouse distance today",
        bundle: .atURL(Bundle.pulse.bundleURL)
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "How far your cursor has travelled today, in metres.",
            bundle: .atURL(Bundle.pulse.bundleURL)
        )
    )
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let store = try PulseIntentBackend.store()
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return .result(value: 0, dialog: "0 m")
        }
        let summary = try store.todaySummary(start: dayStart, end: dayEnd, capUntil: now)
        let metres = summary.totalMouseDistanceMillimeters / 1_000.0
        let metresRounded = (metres * 10).rounded() / 10
        return .result(value: metres, dialog: "\(metresRounded) m today")
    }
}

// MARK: - Suggested shortcuts

/// Surfaces the three intents in the Shortcuts library + Spotlight under
/// pre-built phrases, so users can run them without authoring a custom
/// shortcut. The strings double as Siri trigger phrases on macOS 14+.
struct PulseAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTodayKeystrokesIntent(),
            phrases: [
                "How many keystrokes today on \(.applicationName)",
                "\(.applicationName) keystrokes today"
            ],
            shortTitle: LocalizedStringResource(
                "Keystrokes today",
                bundle: .atURL(Bundle.pulse.bundleURL)
            ),
            systemImageName: "keyboard"
        )
        AppShortcut(
            intent: GetTodayMouseDistanceIntent(),
            phrases: [
                "How far did my mouse travel today on \(.applicationName)",
                "\(.applicationName) mouse distance today"
            ],
            shortTitle: LocalizedStringResource(
                "Mouse distance today",
                bundle: .atURL(Bundle.pulse.bundleURL)
            ),
            systemImageName: "computermouse"
        )
        AppShortcut(
            intent: GetAppUsageTodayIntent(),
            phrases: [
                "How long did I use an app today on \(.applicationName)",
                "\(.applicationName) app usage today"
            ],
            shortTitle: LocalizedStringResource(
                "App usage today",
                bundle: .atURL(Bundle.pulse.bundleURL)
            ),
            systemImageName: "app.dashed"
        )
    }
}

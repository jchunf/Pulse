#if canImport(AppKit)
import Foundation
import PulseCore

/// Curated preset goals shipped with Pulse. The Settings panel exposes
/// these as four toggles rather than a free-form editor — shipping
/// opinionated defaults beats asking the user to invent them. The `id`
/// strings are also the `UserDefaults` storage keys.
enum GoalPresets {
    static let all: [GoalDefinition] = [
        GoalDefinition(
            id: "focus.active.3h",
            metric: .activeSeconds,
            direction: .atLeast,
            target: 3 * 60 * 60
        ),
        GoalDefinition(
            id: "focus.longest.45m",
            metric: .longestFocusSeconds,
            direction: .atLeast,
            target: 45 * 60
        ),
        GoalDefinition(
            id: "switches.under30",
            metric: .appSwitches,
            direction: .atMost,
            target: 30
        ),
        GoalDefinition(
            id: "keystrokes.5k",
            metric: .keystrokes,
            direction: .atLeast,
            target: 5_000
        )
    ]
}

/// Published-set wrapper around the UserDefaults-backed list of enabled
/// preset goal IDs. Single source of truth shared between Settings
/// (edits) and DashboardModel (reads).
@MainActor
final class GoalsStore: ObservableObject {

    @Published private(set) var enabledIds: Set<String>

    private static let defaultsKey = "pulse.goals.enabledIds"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        self.enabledIds = Set(stored)
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIds.contains(id)
    }

    /// Toggle on/off. Persists after every mutation so a crash between
    /// edits doesn't orphan the checkbox state.
    func setEnabled(_ id: String, enabled: Bool) {
        var next = enabledIds
        if enabled { next.insert(id) }
        else       { next.remove(id) }
        enabledIds = next
        UserDefaults.standard.set(Array(next), forKey: Self.defaultsKey)
    }

    /// Filter the full preset list down to the ones the user opted into.
    func enabledGoals() -> [GoalDefinition] {
        GoalPresets.all.filter { enabledIds.contains($0.id) }
    }
}
#endif

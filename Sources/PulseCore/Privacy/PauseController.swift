import Foundation

/// Centralizes the "is collection currently allowed?" gate.
///
/// Drives two distinct behaviors from `docs/05-privacy.md`:
///
/// - **Pause** (default 30 minutes, auto-resumes) — events that arrive
///   while paused are *dropped silently*; nothing is written, nothing is
///   buffered. The user explicitly opted out for this window, and we honor
///   it by not even keeping the data in memory.
///
/// - **Sensitive period** (user-defined window, also auto-resumes) —
///   semantically identical to pause for the writer's perspective. The
///   distinction matters only for UI presentation (different icons,
///   different status strings).
///
/// Implementation is a tiny state machine over a `Clock` so behavior is
/// deterministic in tests. All public APIs are safe to call from any
/// concurrent context.
public final class PauseController: @unchecked Sendable {

    public enum Reason: String, Sendable, Equatable {
        case userPause
        case sensitivePeriod
    }

    public struct State: Sendable, Equatable {
        public let isActive: Bool
        public let reason: Reason?
        public let resumesAt: Date?

        public init(isActive: Bool, reason: Reason?, resumesAt: Date?) {
            self.isActive = isActive
            self.reason = reason
            self.resumesAt = resumesAt
        }
    }

    private let clock: Clock
    private let lock = NSLock()
    private var pausedUntil: Date?
    private var pauseReason: Reason?

    public init(clock: Clock) {
        self.clock = clock
    }

    /// Pause collection until `now + duration`. If a pause is already active,
    /// the longer remaining duration wins (we never shorten an active pause).
    public func pause(reason: Reason, duration: TimeInterval) {
        precondition(duration > 0, "pause duration must be positive")
        lock.lock(); defer { lock.unlock() }
        let candidate = clock.now.addingTimeInterval(duration)
        if let existing = pausedUntil, existing >= candidate {
            return
        }
        pausedUntil = candidate
        pauseReason = reason
    }

    /// Cancel any active pause immediately. Intended for explicit user action
    /// ("Resume now" menu item).
    public func resume() {
        lock.lock(); defer { lock.unlock() }
        pausedUntil = nil
        pauseReason = nil
    }

    /// Returns true if an event observed `at` should be dropped.
    public func isPaused(at instant: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = pausedUntil else { return false }
        if instant >= until {
            // Auto-resume: clear the state so subsequent observers see
            // a clean snapshot.
            pausedUntil = nil
            pauseReason = nil
            return false
        }
        return true
    }

    /// Snapshot of the current pause state. Driven off the clock so the UI
    /// shows accurate countdowns.
    public func snapshot() -> State {
        lock.lock(); defer { lock.unlock() }
        if let until = pausedUntil, clock.now < until {
            return State(isActive: true, reason: pauseReason, resumesAt: until)
        }
        // Clear stale pause if elapsed.
        if pausedUntil != nil {
            pausedUntil = nil
            pauseReason = nil
        }
        return State(isActive: false, reason: nil, resumesAt: nil)
    }
}

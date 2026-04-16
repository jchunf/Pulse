import Foundation

/// Turns a stream of user-activity events into idle-entered / idle-exited
/// notifications. Pure state machine so we can simulate a full day of
/// activity in a single test with a `FakeClock`.
///
/// Default: 5 minutes of no user-activity events → idle.
/// Corresponds to data column `D-I1` in `docs/03-data-collection.md`.
public final class IdleDetector: @unchecked Sendable {

    /// Transitions emitted to observers.
    public enum Transition: Sendable, Equatable {
        case idleEntered(at: Date)
        case idleExited(at: Date)
    }

    public let idleThreshold: TimeInterval

    private let clock: Clock
    private let lock = NSLock()
    private var lastActivityAt: Date
    private var isIdle: Bool = false

    public init(clock: Clock, idleThresholdSeconds: TimeInterval = 300) {
        self.clock = clock
        self.idleThreshold = idleThresholdSeconds
        self.lastActivityAt = clock.now
    }

    /// Feed an observed event. Returns any idle transition produced by this
    /// event, or nil if no transition occurred.
    ///
    /// Rules:
    /// - A user-activity event always refreshes `lastActivityAt`.
    /// - If we were idle, that refresh also emits an `idleExited`.
    /// - A non-activity event does not affect state directly, but callers can
    ///   still probe time progression via `tick(now:)`.
    @discardableResult
    public func observe(_ event: DomainEvent) -> Transition? {
        lock.lock()
        defer { lock.unlock() }

        guard event.isUserActivity else { return nil }
        let at = event.timestamp
        let transition: Transition?
        if isIdle {
            isIdle = false
            transition = .idleExited(at: at)
        } else {
            transition = nil
        }
        lastActivityAt = at
        return transition
    }

    /// Probe the detector without feeding an event. Lets periodic supervisors
    /// emit `idleEntered` once the threshold elapses. Safe to call from a
    /// timer.
    @discardableResult
    public func tick(now: Date) -> Transition? {
        lock.lock()
        defer { lock.unlock() }

        guard !isIdle else { return nil }
        if now.timeIntervalSince(lastActivityAt) >= idleThreshold {
            isIdle = true
            return .idleEntered(at: now)
        }
        return nil
    }

    /// Snapshot of current state. Intended for the HealthPanel (F-49).
    public struct State: Sendable, Equatable {
        public let isIdle: Bool
        public let lastActivityAt: Date
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return State(isIdle: isIdle, lastActivityAt: lastActivityAt)
    }
}

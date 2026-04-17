import Foundation

/// Decides whether a given event should be persisted in the L0 raw mouse
/// stream. The CGEventTap fires at the system rate (~60 Hz on modern Macs),
/// which is overkill for our needs and wastes battery, especially on Intel
/// Macs (see `docs/04-architecture.md#4.2`).
///
/// Strategy:
/// - When the user is "active" (an event arrived within the last
///   `idleWindow`), allow events at up to `activeRateHz`.
/// - When the user is "idle" (no events for `idleWindow`), drop down to
///   `idleRateHz`.
/// - Aggregate counters (sec_mouse, sec_key) are *not* throttled — every
///   event still bumps the count. Sampling only affects the L0 raw rows
///   that feed the heatmap.
///
/// Pure logic; takes a `Clock` so tests are deterministic.
public final class SamplingPolicy: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {
        public let activeRateHz: Double
        public let idleRateHz: Double
        public let idleWindow: TimeInterval

        public init(
            activeRateHz: Double = 30,
            idleRateHz: Double = 1,
            idleWindow: TimeInterval = 30
        ) {
            precondition(activeRateHz > 0, "activeRateHz must be positive")
            precondition(idleRateHz > 0, "idleRateHz must be positive")
            precondition(idleWindow > 0, "idleWindow must be positive")
            self.activeRateHz = activeRateHz
            self.idleRateHz = idleRateHz
            self.idleWindow = idleWindow
        }

        public static let `default` = Configuration()
    }

    private let clock: Clock
    private let configuration: Configuration
    private let lock = NSLock()
    private var lastAcceptedAt: Date?
    private var lastActivityAt: Date?

    public init(clock: Clock, configuration: Configuration = .default) {
        self.clock = clock
        self.configuration = configuration
    }

    /// Returns `true` if `at` should be written, `false` if it should be
    /// dropped. Always records the timestamp as user activity so the next
    /// call has correct context (even when the event is dropped).
    public func shouldRecord(at instant: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }

        let isActive: Bool
        if let last = lastActivityAt, instant.timeIntervalSince(last) < configuration.idleWindow {
            isActive = true
        } else {
            isActive = false
        }
        lastActivityAt = instant

        let rateHz = isActive ? configuration.activeRateHz : configuration.idleRateHz
        let minInterval = 1.0 / rateHz

        if let lastAccepted = lastAcceptedAt,
           instant.timeIntervalSince(lastAccepted) < minInterval {
            return false
        }
        lastAcceptedAt = instant
        return true
    }
}

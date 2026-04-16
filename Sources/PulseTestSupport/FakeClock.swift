import Foundation
import PulseCore

/// A deterministic clock for unit tests. Start at a fixed instant and use
/// `advance(_:)` to fast-forward. Monotonic time advances in lock-step with
/// wall time, which is fine for our tests (they care about relative durations,
/// not clock-skew resistance).
public final class FakeClock: Clock, @unchecked Sendable {

    private let lock = NSLock()
    private var currentInstant: Date
    private var currentMonotonic: Double

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentInstant = start
        self.currentMonotonic = 0
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return currentInstant
    }

    public var monotonicSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return currentMonotonic
    }

    /// Advance both wall and monotonic clocks by `seconds`.
    public func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        currentInstant = currentInstant.addingTimeInterval(seconds)
        currentMonotonic += seconds
    }

    /// Jump the wall clock to a specific instant (does not touch monotonic).
    /// Useful for simulating NTP adjustments or DST boundaries.
    public func setWallClock(_ instant: Date) {
        lock.lock(); defer { lock.unlock() }
        currentInstant = instant
    }
}

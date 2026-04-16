import Foundation

/// Abstract time source so time-dependent logic (rollups, idle detection,
/// rate limiting) is testable with a `FakeClock` from `PulseTestSupport`.
///
/// All production code that needs the current time MUST take a `Clock` rather
/// than calling `Date()` directly. This is enforced by code review (and
/// enables the TDD strategy described in `docs/10-testing-and-ci.md`).
public protocol Clock: Sendable {
    /// Returns the current wall-clock instant in UTC.
    var now: Date { get }

    /// Returns a monotonic duration since an arbitrary fixed origin,
    /// unaffected by NTP adjustments / DST. Use for measuring elapsed time.
    var monotonicSeconds: Double { get }
}

/// Production clock backed by `Foundation`. Uses `Date()` for wall clock and
/// `CFAbsoluteTimeGetCurrent()` for monotonic-ish duration (good enough for
/// Pulse's sub-second precision needs).
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public var monotonicSeconds: Double {
        CFAbsoluteTimeGetCurrent()
    }
}

import Foundation

/// The domain event model. Every observation Pulse makes flows through one of
/// these cases. Kept deliberately narrow: anything richer (raw `CGEvent`
/// details, `NSRunningApplication`) is translated to these cases at the
/// platform boundary so that `PulseCore` stays platform-independent.
///
/// Notes:
/// - No keystroke character content is ever represented. Only counts, timing
///   and keycode (opt-in) distributions. See `docs/05-privacy.md`.
/// - Mouse coordinates are already normalized to `[0, 1]` with the display
///   identifier attached. See `CoordNormalizer` and
///   `docs/04-architecture.md#4.1`.
public enum DomainEvent: Sendable, Equatable {
    case mouseMove(NormalizedPoint, at: Date)
    case mouseClick(MouseButton, point: NormalizedPoint, doubleClick: Bool, at: Date)
    case mouseScroll(delta: Double, horizontal: Bool, at: Date)
    case keyPress(keyCode: UInt16?, at: Date)
    case foregroundApp(bundleId: String, at: Date)
    case windowTitleHash(appBundleId: String, titleSHA256: String, at: Date)
    case idleEntered(at: Date)
    case idleExited(at: Date)
    case systemSleep(at: Date)
    case systemWake(at: Date)
    case screenLocked(at: Date)
    case screenUnlocked(at: Date)
    case lidClosed(at: Date)
    case lidOpened(at: Date)
    case powerChanged(isOnBattery: Bool, percent: Int, at: Date)
    case displayConfigChanged(at: Date)

    /// The timestamp this event was observed.
    public var timestamp: Date {
        switch self {
        case .mouseMove(_, let at),
             .mouseClick(_, _, _, let at),
             .mouseScroll(_, _, let at),
             .keyPress(_, let at),
             .foregroundApp(_, let at),
             .windowTitleHash(_, _, let at),
             .idleEntered(let at),
             .idleExited(let at),
             .systemSleep(let at),
             .systemWake(let at),
             .screenLocked(let at),
             .screenUnlocked(let at),
             .lidClosed(let at),
             .lidOpened(let at),
             .powerChanged(_, _, let at),
             .displayConfigChanged(let at):
            return at
        }
    }

    /// Whether this event represents user activity (for idle detection).
    /// System state transitions do not count.
    public var isUserActivity: Bool {
        switch self {
        case .mouseMove, .mouseClick, .mouseScroll, .keyPress:
            return true
        case .foregroundApp, .windowTitleHash, .idleEntered, .idleExited,
             .systemSleep, .systemWake, .screenLocked, .screenUnlocked,
             .lidClosed, .lidOpened, .powerChanged, .displayConfigChanged:
            return false
        }
    }
}

public enum MouseButton: String, Sendable, Equatable, CaseIterable {
    case left, right, middle, other
}

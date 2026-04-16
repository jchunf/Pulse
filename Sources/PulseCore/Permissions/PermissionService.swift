import Foundation

/// The macOS permissions Pulse cares about. Extend as C-group features
/// (location, calendar, notifications) land in later phases.
public enum Permission: String, Sendable, Equatable, CaseIterable {
    case inputMonitoring
    case accessibility
    case calendars
    case location
    case notifications
}

/// The status of a single permission.
public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// An abstract permission inspector. The live implementation in
/// `PulsePlatform` calls `IOHIDCheckAccess`, `AXIsProcessTrusted`, etc.
/// Tests inject a `FakePermissionService` to simulate any combination of
/// states, including mid-session permission loss (a common macOS reality).
public protocol PermissionService: Sendable {
    func status(of permission: Permission) -> PermissionStatus
    func requestAccess(for permission: Permission) async
}

/// A snapshot of all permissions at a moment in time, suitable for the
/// HealthPanel (F-49) and for UI icon state.
public struct PermissionSnapshot: Sendable, Equatable {
    public let statuses: [Permission: PermissionStatus]
    public let capturedAt: Date

    public init(statuses: [Permission: PermissionStatus], capturedAt: Date) {
        self.statuses = statuses
        self.capturedAt = capturedAt
    }

    /// True only if every required permission is granted. `inputMonitoring`
    /// and `accessibility` are required for MVP; others are optional.
    public var isAllRequiredGranted: Bool {
        requiredStatus(.inputMonitoring) == .granted
            && requiredStatus(.accessibility) == .granted
    }

    private func requiredStatus(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }
}

public extension PermissionService {
    /// Convenience snapshot helper used by the HealthPanel. Captures all
    /// declared permissions at `capturedAt`.
    func snapshot(at now: Date) -> PermissionSnapshot {
        var statuses: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases {
            statuses[permission] = status(of: permission)
        }
        return PermissionSnapshot(statuses: statuses, capturedAt: now)
    }
}

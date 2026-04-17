import Foundation

/// The macOS permissions Pulse cares about. Extend as C-group features
/// (location, calendar, notifications) land in later phases.
public enum Permission: String, Sendable, Equatable, CaseIterable {
    case inputMonitoring
    case accessibility
    case calendars
    case location
    case notifications

    /// MVP requires these; others are optional and only land with their
    /// feature-flagged consumers.
    public static let required: [Permission] = [.inputMonitoring, .accessibility]

    /// Deep-link URL that jumps straight to this permission's pane in
    /// System Settings. Constructed as a pure `URL` (no AppKit) so it can
    /// live in PulseCore; callers in PulsePlatform / PulseApp open it via
    /// `NSWorkspace`.
    public var systemSettingsURL: URL? {
        switch self {
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .calendars:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .location:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        }
    }

    /// Human-facing label used by the permission-assistant UI. Stable
    /// across locales at MVP; full localization lands with the app-wide
    /// l10n pass.
    public var displayName: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility:   return "Accessibility"
        case .calendars:       return "Calendars"
        case .location:        return "Location Services"
        case .notifications:   return "Notifications"
        }
    }
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
        Permission.required.allSatisfy { requiredStatus($0) == .granted }
    }

    /// Required permissions whose status is anything other than `.granted`.
    /// The permission-assistant UI uses this to list the exact fixes the
    /// user still needs to complete; order matches `Permission.required`.
    public var missingRequired: [Permission] {
        Permission.required.filter { requiredStatus($0) != .granted }
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

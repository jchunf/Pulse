import Foundation
import CoreGraphics
import PulseCore

/// Umbrella entry point for the `PulsePlatform` module. Exposes a single
/// `PulsePlatform` facade that wires together the live Adapters for use by
/// `PulseApp`. Non-macOS builds (e.g. the CI Linux smoke) still compile this
/// module but do not exercise the guarded Adapters.
public enum PulsePlatform {

    /// Returns the best-available permission service for the current
    /// platform. Returns a "deny-all" permission service on non-macOS hosts
    /// so callers can still boot a read-only smoke test.
    public static func permissionService() -> PermissionService {
        #if canImport(AppKit)
        return SystemPermissionService()
        #else
        return DenyAllPermissionService()
        #endif
    }

    /// Returns the best-available display registry for the current platform.
    /// On non-macOS the registry reports an empty display list.
    public static func displayRegistry() -> DisplayRegistry {
        #if canImport(AppKit)
        return LiveDisplayRegistry()
        #else
        return EmptyDisplayRegistry()
        #endif
    }

    /// Static build fingerprint useful for health diagnostics.
    public static let buildFingerprint: String = "pulse-b2-live-collector"
}

/// Fallback service used on unsupported platforms.
private struct DenyAllPermissionService: PermissionService {
    func status(of permission: Permission) -> PermissionStatus { .denied }
    func requestAccess(for permission: Permission) async {}
}

/// Fallback display registry used on unsupported platforms.
private struct EmptyDisplayRegistry: DisplayRegistry {
    var displays: [DisplayInfo] { [] }
    func display(containing globalPoint: CGPoint) -> DisplayInfo? { nil }
}

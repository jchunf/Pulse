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

    /// Human-readable version string for the Settings → About row
    /// and any other "what version is running?" surface. Reads
    /// `CFBundleShortVersionString` (the marketing version, e.g.
    /// `2.0.1` or `0.0.0-dev.240+abc`) and `CFBundleVersion` (the
    /// monotonic build number Sparkle compares against), and joins
    /// them so the user sees both — the short version is what
    /// they'd say out loud, the build number is what Sparkle uses.
    ///
    /// Returns an em-dash for either field on a non-`AppKit` host
    /// (CI smoke), where `Bundle.main` is the test runner rather
    /// than a `.app`.
    public static var buildFingerprint: String {
        let bundle = Bundle.main
        let short = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        return "\(short) (build \(build))"
    }
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

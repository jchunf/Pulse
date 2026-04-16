#if canImport(AppKit)
import AppKit
import PulseCore

#if canImport(IOKit)
import IOKit.hid
#endif

/// Live permission service backed by the real macOS APIs:
/// - Input Monitoring: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`
/// - Accessibility: `AXIsProcessTrustedWithOptions`
///
/// Consults the system directly on each call; caches nothing. Callers that
/// want a cheap repeatable value should take a `PermissionSnapshot` from
/// `PermissionService.snapshot(at:)` in `PulseCore`.
public struct SystemPermissionService: PermissionService {

    public init() {}

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .inputMonitoring:
            return checkInputMonitoring()
        case .accessibility:
            return checkAccessibility()
        case .calendars, .location, .notifications:
            // These are requested lazily when the user enables the feature
            // that needs them (see docs/06-onboarding-permissions.md). B1
            // does not exercise them.
            return .notDetermined
        }
    }

    public func requestAccess(for permission: Permission) async {
        switch permission {
        case .accessibility:
            _ = promptAccessibility()
        case .inputMonitoring:
            // macOS has no direct "request" API for Input Monitoring —
            // simply attempting to create a CGEventTap triggers the system
            // prompt. B2 will do this from the collector lifecycle.
            break
        case .calendars, .location, .notifications:
            // Handled by the feature module that owns the permission.
            break
        }
    }

    // MARK: - Private

    private func checkInputMonitoring() -> PermissionStatus {
        #if canImport(IOKit)
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .notDetermined
        default:
            return .unknown
        }
        #else
        return .unknown
        #endif
    }

    private func checkAccessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @discardableResult
    private func promptAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue!] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
#endif

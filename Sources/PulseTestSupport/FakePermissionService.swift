import Foundation
import PulseCore

/// A `PermissionService` whose state is entirely controlled by the test.
/// Scenarios exercised include: "all granted", "none granted", "started
/// granted then lost input monitoring" (simulating the common macOS behavior
/// of permissions being revoked on OS upgrade).
public final class FakePermissionService: PermissionService, @unchecked Sendable {

    private let lock = NSLock()
    private var statuses: [Permission: PermissionStatus]
    public private(set) var requestCounts: [Permission: Int]

    public init(initialStatuses: [Permission: PermissionStatus] = [:]) {
        self.statuses = initialStatuses
        self.requestCounts = [:]
    }

    public func status(of permission: Permission) -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return statuses[permission] ?? .notDetermined
    }

    public func requestAccess(for permission: Permission) async {
        lock.lock()
        requestCounts[permission, default: 0] += 1
        lock.unlock()
    }

    /// Directly set a permission's status. Test-only.
    public func setStatus(_ status: PermissionStatus, for permission: Permission) {
        lock.lock(); defer { lock.unlock() }
        statuses[permission] = status
    }

    /// Convenience: grant all defined permissions.
    public static func allGranted() -> FakePermissionService {
        var map: [Permission: PermissionStatus] = [:]
        for p in Permission.allCases { map[p] = .granted }
        return FakePermissionService(initialStatuses: map)
    }

    /// Convenience: deny all defined permissions.
    public static func allDenied() -> FakePermissionService {
        var map: [Permission: PermissionStatus] = [:]
        for p in Permission.allCases { map[p] = .denied }
        return FakePermissionService(initialStatuses: map)
    }
}

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
        readStatus(of: permission)
    }

    public func requestAccess(for permission: Permission) async {
        // Delegated to a sync helper. Holding a lock across an async body
        // would trip the Swift 6 noasync diagnostic on NSLock; keeping the
        // critical section entirely synchronous avoids it.
        recordRequest(for: permission)
    }

    /// Directly set a permission's status. Test-only.
    public func setStatus(_ status: PermissionStatus, for permission: Permission) {
        lock.lock(); defer { lock.unlock() }
        statuses[permission] = status
    }

    // MARK: - Private sync helpers (NSLock-using critical sections stay sync)

    private func readStatus(of permission: Permission) -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return statuses[permission] ?? .notDetermined
    }

    private func recordRequest(for permission: Permission) {
        lock.lock(); defer { lock.unlock() }
        requestCounts[permission, default: 0] += 1
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

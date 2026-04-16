import Testing
import PulseCore
@testable import PulsePlatform

/// Smoke tests for the platform module. Most live adapters require a real
/// macOS GUI session and granted permissions, so we only assert that the
/// non-privileged surface (build fingerprint, fallback permission service)
/// behaves as expected. B2 adds richer platform tests gated on the CI
/// environment.
@Suite("PulsePlatform smoke")
struct PulsePlatformSmokeTests {

    @Test("build fingerprint is set")
    func fingerprint() {
        #expect(!PulsePlatform.buildFingerprint.isEmpty)
    }

    @Test("default permission service resolves")
    func permissionServiceResolves() {
        let service = PulsePlatform.permissionService()
        // We only assert that calling status(of:) does not crash. The actual
        // status depends on the runner's environment.
        let status = service.status(of: .inputMonitoring)
        #expect([.granted, .denied, .notDetermined, .unknown].contains(status))
    }
}

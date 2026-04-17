import Testing
import Foundation
@testable import PulseCore
import PulseTestSupport

@Suite("Permission — required set, missing-required, and system-settings URLs")
struct PermissionServiceTests {

    @Test("required set lists inputMonitoring and accessibility only")
    func requiredSet() {
        #expect(Permission.required == [.inputMonitoring, .accessibility])
    }

    @Test("systemSettingsURL is a Privacy pane deep-link for every permission")
    func systemSettingsURLs() {
        for permission in Permission.allCases {
            let url = permission.systemSettingsURL
            #expect(url != nil, "missing systemSettingsURL for \(permission.rawValue)")
            #expect(url?.scheme == "x-apple.systempreferences")
        }
    }

    @Test("displayName is non-empty for every permission")
    func displayNames() {
        for permission in Permission.allCases {
            #expect(!permission.displayName.isEmpty)
        }
    }

    @Test("missingRequired returns required permissions that are not granted")
    func missingRequiredReportsGaps() {
        let snapshot = PermissionSnapshot(
            statuses: [
                .inputMonitoring: .denied,
                .accessibility: .granted,
                .notifications: .denied  // optional — must not surface
            ],
            capturedAt: Date()
        )
        #expect(snapshot.missingRequired == [.inputMonitoring])
        #expect(snapshot.isAllRequiredGranted == false)
    }

    @Test("missingRequired is empty when all required permissions are granted")
    func missingRequiredEmptyWhenSatisfied() {
        let snapshot = PermissionSnapshot(
            statuses: [
                .inputMonitoring: .granted,
                .accessibility: .granted
            ],
            capturedAt: Date()
        )
        #expect(snapshot.missingRequired.isEmpty)
        #expect(snapshot.isAllRequiredGranted == true)
    }

    @Test("missingRequired preserves the canonical ordering")
    func missingRequiredOrdering() {
        let snapshot = PermissionSnapshot(
            statuses: [
                .inputMonitoring: .denied,
                .accessibility: .notDetermined
            ],
            capturedAt: Date()
        )
        #expect(snapshot.missingRequired == [.inputMonitoring, .accessibility])
    }
}

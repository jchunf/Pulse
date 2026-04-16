import Testing
import Foundation
@testable import PulseCore

@Suite("HealthSnapshot — derived status messages and silent-failure detection")
struct HealthSnapshotTests {

    private func makeSnapshot(
        isRunning: Bool = true,
        pause: PauseController.State = .init(isActive: false, reason: nil, resumesAt: nil),
        permissionsAllGranted: Bool = true,
        lastWriteSecondsAgo: TimeInterval? = 1
    ) -> HealthSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let permissions = PermissionSnapshot(
            statuses: [
                .inputMonitoring: permissionsAllGranted ? .granted : .denied,
                .accessibility:   permissionsAllGranted ? .granted : .denied
            ],
            capturedAt: now
        )
        let lastWrite: Date? = lastWriteSecondsAgo.map { now.addingTimeInterval(-$0) }
        return HealthSnapshot(
            capturedAt: now,
            isRunning: isRunning,
            pause: pause,
            permissions: permissions,
            writer: .empty,
            rollupStamps: .empty,
            l0Counts: L0Counts(mouseMoves: 0, mouseClicks: 0, keyEvents: 0),
            databaseFileSizeBytes: nil,
            lastWriteAt: lastWrite
        )
    }

    @Test("a healthy running snapshot is not silently failing")
    func healthy() {
        let snap = makeSnapshot()
        #expect(snap.isSilentlyFailing == false)
        #expect(snap.statusHeadline == "Listening to your pulse.")
    }

    @Test("paused snapshot reports user-pause headline")
    func pausedHeadline() {
        let snap = makeSnapshot(
            pause: .init(isActive: true, reason: .userPause, resumesAt: nil)
        )
        #expect(snap.isSilentlyFailing == false)
        #expect(snap.statusHeadline.contains("Paused"))
    }

    @Test("sensitive-period pause uses its specific headline")
    func sensitivePeriodHeadline() {
        let snap = makeSnapshot(
            pause: .init(isActive: true, reason: .sensitivePeriod, resumesAt: nil)
        )
        #expect(snap.statusHeadline.contains("Sensitive"))
    }

    @Test("missing permissions surface their own headline")
    func missingPermissions() {
        let snap = makeSnapshot(permissionsAllGranted: false)
        #expect(snap.isSilentlyFailing == false, "we don't blame the collector when perms are missing")
        #expect(snap.statusHeadline == "Waiting for permissions.")
    }

    @Test("no writes for over 60s while everything else is healthy is a silent failure")
    func silentFailureDetected() {
        let snap = makeSnapshot(lastWriteSecondsAgo: 90)
        #expect(snap.isSilentlyFailing == true)
        #expect(snap.statusHeadline.contains("Collector idle"))
    }

    @Test("never having written anything is a silent failure")
    func neverWrote() {
        let snap = makeSnapshot(lastWriteSecondsAgo: nil)
        #expect(snap.isSilentlyFailing == true)
    }

    @Test("paused snapshots are exempt from silent-failure detection")
    func pausedExempt() {
        let snap = makeSnapshot(
            pause: .init(isActive: true, reason: .userPause, resumesAt: nil),
            lastWriteSecondsAgo: 600
        )
        #expect(snap.isSilentlyFailing == false)
    }

    @Test("not-running snapshot says Stopped")
    func notRunning() {
        let snap = makeSnapshot(isRunning: false)
        #expect(snap.statusHeadline == "Stopped.")
    }
}

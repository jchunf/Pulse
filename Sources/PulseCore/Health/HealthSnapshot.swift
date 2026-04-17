import Foundation

/// What the HealthPanel (F-49) shows the user. Computed off the database
/// + runtime state; safe to compute as often as the UI redraws.
public struct HealthSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let isRunning: Bool
    public let pause: PauseController.State
    public let permissions: PermissionSnapshot
    public let writer: WriterStats
    public let rollupStamps: RollupScheduler.LastRunStamps
    public let l0Counts: L0Counts
    public let databaseFileSizeBytes: Int64?
    public let lastWriteAt: Date?

    public init(
        capturedAt: Date,
        isRunning: Bool,
        pause: PauseController.State,
        permissions: PermissionSnapshot,
        writer: WriterStats,
        rollupStamps: RollupScheduler.LastRunStamps,
        l0Counts: L0Counts,
        databaseFileSizeBytes: Int64?,
        lastWriteAt: Date?
    ) {
        self.capturedAt = capturedAt
        self.isRunning = isRunning
        self.pause = pause
        self.permissions = permissions
        self.writer = writer
        self.rollupStamps = rollupStamps
        self.l0Counts = l0Counts
        self.databaseFileSizeBytes = databaseFileSizeBytes
        self.lastWriteAt = lastWriteAt
    }

    /// Treat the collector as "silently failed" if there has been no write
    /// for 60 seconds while the user is supposedly active. Used to flip the
    /// menu bar icon to a warning state.
    public var isSilentlyFailing: Bool {
        guard isRunning, !pause.isActive, permissions.isAllRequiredGranted else {
            return false
        }
        guard let last = lastWriteAt else { return true }
        return capturedAt.timeIntervalSince(last) > 60
    }

    /// Human-friendly headline used by the menu popover.
    public var statusHeadline: String {
        if pause.isActive {
            switch pause.reason {
            case .userPause:        return "Paused — collection resumes shortly."
            case .sensitivePeriod:  return "Sensitive period active."
            case .none:             return "Paused."
            }
        }
        if !permissions.isAllRequiredGranted {
            return "Waiting for permissions."
        }
        if isSilentlyFailing {
            return "Collector idle — please open settings."
        }
        if isRunning {
            return "Listening to your pulse."
        }
        return "Stopped."
    }
}

import Foundation

/// F-45 — local fatigue / usage reminders. Two alert kinds ship in this
/// slice:
///
/// - `.screenTimeExceeded(seconds:)` when today's cumulative active
///   time crosses a user-chosen threshold (default 8 h).
/// - `.noBreakSince(lastActivityStart:threshold:)` when the user has
///   been continuously active (no idle segment) longer than their
///   chosen threshold (default 2 h).
///
/// The evaluator is pure — it takes the current day's summary plus
/// the user's enabled thresholds plus a "last-fired" memory per
/// alert type, and returns the alerts that should fire *now*. All
/// wall-clock, notification-permission, and persistence concerns
/// live in the app layer.
public enum ThresholdAlertKind: Sendable, Equatable {
    case screenTimeExceeded(thresholdSeconds: Int, actualSeconds: Int)
    case noBreakSince(thresholdSeconds: Int, actualSeconds: Int)

    /// Stable identifier used as the persistence key ("has this kind
    /// already fired today?"). Two alerts of the same kind collapse.
    public var identifier: String {
        switch self {
        case .screenTimeExceeded: return "screenTimeExceeded"
        case .noBreakSince:       return "noBreakSince"
        }
    }
}

/// User-facing settings for the alert engine. Each field is nullable
/// when the alert is disabled — a disabled alert never fires regardless
/// of the metric value.
public struct ThresholdAlertSettings: Sendable, Equatable {
    public var screenTimeSecondsThreshold: Int?
    public var noBreakSecondsThreshold: Int?

    public init(
        screenTimeSecondsThreshold: Int? = nil,
        noBreakSecondsThreshold: Int? = nil
    ) {
        self.screenTimeSecondsThreshold = screenTimeSecondsThreshold
        self.noBreakSecondsThreshold = noBreakSecondsThreshold
    }

    /// The defaults the Settings panel pre-populates when the user
    /// first flips either toggle on.
    public static let defaults = ThresholdAlertSettings(
        screenTimeSecondsThreshold: 8 * 60 * 60,
        noBreakSecondsThreshold: 2 * 60 * 60
    )
}

/// Metrics the evaluator needs on every tick. Mirror of the subset of
/// `DashboardModel` state the controller reads; kept as a separate
/// type so tests don't have to stand up the full model.
public struct ThresholdAlertMetrics: Sendable, Equatable {
    public let activeSecondsToday: Int
    /// Seconds since the last idle segment ended, or since the start
    /// of the active run when no idle event has fired today yet.
    /// `nil` when the user hasn't been active at all.
    public let continuousActiveSeconds: Int?

    public init(activeSecondsToday: Int, continuousActiveSeconds: Int?) {
        self.activeSecondsToday = activeSecondsToday
        self.continuousActiveSeconds = continuousActiveSeconds
    }
}

/// Per-alert-kind "already fired today" memory. The controller
/// persists this under UserDefaults and hands it to the evaluator on
/// every tick; fresh-day bookkeeping is the controller's job.
public struct ThresholdAlertMemory: Sendable, Equatable {
    /// Alert-kind identifiers that have already fired today. Opaque
    /// strings — matches `ThresholdAlertKind.identifier`.
    public var firedKinds: Set<String>

    public init(firedKinds: Set<String> = []) {
        self.firedKinds = firedKinds
    }
}

/// Derives `continuousActiveSeconds` from today's rest segments plus
/// the current wall-clock. Returns `nil` when the user is still idle
/// right now (the latest segment ends within `stillIdleGraceSeconds`
/// of `now`) so the "no break" alert never fires while the user is
/// already on break.
public enum ContinuousActiveDeriver {
    /// `stillIdleGraceSeconds` matches the poll cadence (5 s today)
    /// plus a small margin — `restSegments` close an open segment at
    /// the `capUntil` the caller passes in, which in `refresh` is
    /// exactly `now`, so any open idle sits right on the boundary.
    public static let stillIdleGraceSeconds: TimeInterval = 30

    public static func derive(
        restSegments: [(startedAt: Date, endedAt: Date)],
        dayStart: Date,
        now: Date
    ) -> Int? {
        guard now >= dayStart else { return nil }
        if let last = restSegments.last,
           now.timeIntervalSince(last.endedAt) < stillIdleGraceSeconds {
            return nil
        }
        let anchor = restSegments.last?.endedAt ?? dayStart
        let seconds = Int(now.timeIntervalSince(anchor))
        return max(0, seconds)
    }
}

public enum ThresholdAlertEvaluator {

    /// Returns the alerts that should fire right now. Does *not*
    /// mutate `memory` — the controller is responsible for recording
    /// fired kinds after it actually delivers the notification.
    public static func evaluate(
        settings: ThresholdAlertSettings,
        metrics: ThresholdAlertMetrics,
        memory: ThresholdAlertMemory
    ) -> [ThresholdAlertKind] {
        var out: [ThresholdAlertKind] = []

        if let threshold = settings.screenTimeSecondsThreshold,
           metrics.activeSecondsToday >= threshold,
           !memory.firedKinds.contains("screenTimeExceeded") {
            out.append(.screenTimeExceeded(
                thresholdSeconds: threshold,
                actualSeconds: metrics.activeSecondsToday
            ))
        }

        if let threshold = settings.noBreakSecondsThreshold,
           let continuous = metrics.continuousActiveSeconds,
           continuous >= threshold,
           !memory.firedKinds.contains("noBreakSince") {
            out.append(.noBreakSince(
                thresholdSeconds: threshold,
                actualSeconds: continuous
            ))
        }

        return out
    }
}

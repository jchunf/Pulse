import Foundation
import GRDB

/// Periodically rolls L0 raw events up into L1/L2/L3 aggregates and purges
/// expired rows. Pure SQL for performance — we never roundtrip events
/// through Swift. The schedule cadence comes from `Configuration`; tests
/// drive it manually via `runOnce(...)` rather than waiting on a timer.
///
/// All jobs are idempotent: re-running them on a steady-state DB produces
/// no duplicate rows (UPSERT behavior on the aggregate tables, DELETE
/// guarded by the cutoff helpers in `AggregationRules`).
public final class RollupScheduler: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {
        public let secondsToMinutesInterval: TimeInterval
        public let minutesToHoursInterval: TimeInterval
        public let purgeInterval: TimeInterval
        public let rawToSecondInterval: TimeInterval

        public init(
            rawToSecondInterval: TimeInterval = 60,
            secondsToMinutesInterval: TimeInterval = 300,
            minutesToHoursInterval: TimeInterval = 3_600,
            purgeInterval: TimeInterval = 86_400
        ) {
            self.rawToSecondInterval = rawToSecondInterval
            self.secondsToMinutesInterval = secondsToMinutesInterval
            self.minutesToHoursInterval = minutesToHoursInterval
            self.purgeInterval = purgeInterval
        }

        public static let `default` = Configuration()
    }

    public enum Job: String, Sendable, Equatable, CaseIterable {
        case rawToSecond
        case secondToMinute
        case minuteToHour
        case purgeExpired
    }

    public struct LastRunStamps: Sendable, Equatable {
        public var rawToSecond: Date?
        public var secondToMinute: Date?
        public var minuteToHour: Date?
        public var purgeExpired: Date?

        public static let empty = LastRunStamps(
            rawToSecond: nil, secondToMinute: nil, minuteToHour: nil, purgeExpired: nil
        )
    }

    private let database: PulseDatabase
    private let clock: Clock
    private let configuration: Configuration
    private let lock = NSLock()
    private var lastRuns: LastRunStamps = .empty

    public init(
        database: PulseDatabase,
        clock: Clock,
        configuration: Configuration = .default
    ) {
        self.database = database
        self.clock = clock
        self.configuration = configuration
    }

    public var stamps: LastRunStamps {
        lock.lock(); defer { lock.unlock() }
        return lastRuns
    }

    /// Decide which jobs are due at `now` and execute them. Returns the set
    /// of jobs that ran (useful for tests and the HealthPanel).
    @discardableResult
    public func tick(now: Date) throws -> Set<Job> {
        var ranNow: Set<Job> = []
        for job in Job.allCases where shouldRun(job, at: now) {
            try runOnce(job, now: now)
            ranNow.insert(job)
        }
        return ranNow
    }

    public func runOnce(_ job: Job, now: Date) throws {
        switch job {
        case .rawToSecond:    try rollRawToSecond(now: now)
        case .secondToMinute: try rollSecondToMinute(now: now)
        case .minuteToHour:   try rollMinuteToHour(now: now)
        case .purgeExpired:   try purgeExpired(now: now)
        }
        lock.lock()
        switch job {
        case .rawToSecond:    lastRuns.rawToSecond = now
        case .secondToMinute: lastRuns.secondToMinute = now
        case .minuteToHour:   lastRuns.minuteToHour = now
        case .purgeExpired:   lastRuns.purgeExpired = now
        }
        lock.unlock()
    }

    // MARK: - Schedule decisions

    private func shouldRun(_ job: Job, at now: Date) -> Bool {
        let last: Date?
        let interval: TimeInterval
        lock.lock()
        switch job {
        case .rawToSecond:
            last = lastRuns.rawToSecond
            interval = configuration.rawToSecondInterval
        case .secondToMinute:
            last = lastRuns.secondToMinute
            interval = configuration.secondsToMinutesInterval
        case .minuteToHour:
            last = lastRuns.minuteToHour
            interval = configuration.minutesToHoursInterval
        case .purgeExpired:
            last = lastRuns.purgeExpired
            interval = configuration.purgeInterval
        }
        lock.unlock()
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - Rollup SQL
    //
    // Each rollup builds aggregates "up to" the bucket containing `now`,
    // intentionally excluding the partial bucket so we never overwrite
    // counts that are still being accumulated. The next run will include
    // it once the bucket is closed.

    private func rollRawToSecond(now: Date) throws {
        let cutoffMillis = Int64(AggregationRules.secondBucket(for: now).timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO sec_mouse (ts_second, move_events, click_events, scroll_ticks, distance_mm)
                SELECT ts / 1000, COUNT(*), 0, 0, 0
                FROM raw_mouse_moves
                WHERE ts < ?
                GROUP BY ts / 1000
                ON CONFLICT(ts_second) DO UPDATE SET
                    move_events = sec_mouse.move_events + excluded.move_events
                """, arguments: [cutoffMillis])

            try db.execute(sql: """
                INSERT INTO sec_mouse (ts_second, move_events, click_events, scroll_ticks, distance_mm)
                SELECT ts / 1000, 0, COUNT(*), 0, 0
                FROM raw_mouse_clicks
                WHERE ts < ?
                GROUP BY ts / 1000
                ON CONFLICT(ts_second) DO UPDATE SET
                    click_events = sec_mouse.click_events + excluded.click_events
                """, arguments: [cutoffMillis])

            try db.execute(sql: """
                INSERT INTO sec_key (ts_second, press_count)
                SELECT ts / 1000, COUNT(*)
                FROM raw_key_events
                WHERE ts < ?
                GROUP BY ts / 1000
                ON CONFLICT(ts_second) DO UPDATE SET
                    press_count = sec_key.press_count + excluded.press_count
                """, arguments: [cutoffMillis])

            // After rolling, mark the rolled rows by deleting them from raw
            // tables that have already been aggregated. Retention purge will
            // also do this on a schedule, but eager removal keeps the L0
            // tables small and roll-ups idempotent.
            try db.execute(sql: "DELETE FROM raw_mouse_moves WHERE ts < ?", arguments: [cutoffMillis])
            try db.execute(sql: "DELETE FROM raw_mouse_clicks WHERE ts < ?", arguments: [cutoffMillis])
            try db.execute(sql: "DELETE FROM raw_key_events WHERE ts < ?", arguments: [cutoffMillis])
        }
    }

    private func rollSecondToMinute(now: Date) throws {
        let cutoffSeconds = Int64(AggregationRules.minuteBucket(for: now).timeIntervalSince1970)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO min_mouse (ts_minute, move_events, click_events, scroll_ticks, distance_mm)
                SELECT (ts_second / 60) * 60,
                       SUM(move_events), SUM(click_events), SUM(scroll_ticks), SUM(distance_mm)
                FROM sec_mouse
                WHERE ts_second < ?
                GROUP BY ts_second / 60
                ON CONFLICT(ts_minute) DO UPDATE SET
                    move_events  = min_mouse.move_events  + excluded.move_events,
                    click_events = min_mouse.click_events + excluded.click_events,
                    scroll_ticks = min_mouse.scroll_ticks + excluded.scroll_ticks,
                    distance_mm  = min_mouse.distance_mm  + excluded.distance_mm
                """, arguments: [cutoffSeconds])

            try db.execute(sql: """
                INSERT INTO min_key (ts_minute, press_count)
                SELECT (ts_second / 60) * 60, SUM(press_count)
                FROM sec_key
                WHERE ts_second < ?
                GROUP BY ts_second / 60
                ON CONFLICT(ts_minute) DO UPDATE SET
                    press_count = min_key.press_count + excluded.press_count
                """, arguments: [cutoffSeconds])

            try db.execute(sql: "DELETE FROM sec_mouse WHERE ts_second < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM sec_key WHERE ts_second < ?", arguments: [cutoffSeconds])
        }
    }

    private func rollMinuteToHour(now: Date) throws {
        let cutoffSeconds = Int64(AggregationRules.hourBucket(for: now).timeIntervalSince1970)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds)
                SELECT (mm.ts_minute / 3600) * 3600,
                       COALESCE(SUM(mk.press_count), 0),
                       COALESCE(SUM(mm.distance_mm), 0.0),
                       COALESCE(SUM(mm.click_events), 0),
                       0
                FROM min_mouse mm
                LEFT JOIN min_key mk ON mk.ts_minute = mm.ts_minute
                WHERE mm.ts_minute < ?
                GROUP BY mm.ts_minute / 3600
                ON CONFLICT(ts_hour) DO UPDATE SET
                    key_press_total   = hour_summary.key_press_total   + excluded.key_press_total,
                    mouse_distance_mm = hour_summary.mouse_distance_mm + excluded.mouse_distance_mm,
                    mouse_click_total = hour_summary.mouse_click_total + excluded.mouse_click_total
                """, arguments: [cutoffSeconds])

            // Idle aggregation is independent (only sourced from min_idle).
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds)
                SELECT (ts_minute / 3600) * 3600, 0, 0.0, 0, SUM(idle_seconds)
                FROM min_idle
                WHERE ts_minute < ?
                GROUP BY ts_minute / 3600
                ON CONFLICT(ts_hour) DO UPDATE SET
                    idle_seconds = hour_summary.idle_seconds + excluded.idle_seconds
                """, arguments: [cutoffSeconds])

            try db.execute(sql: "DELETE FROM min_mouse WHERE ts_minute < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM min_key WHERE ts_minute < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM min_idle WHERE ts_minute < ?", arguments: [cutoffSeconds])
        }
    }

    private func purgeExpired(now: Date) throws {
        let rawCutoffMs = Int64(AggregationRules.rawCutoff(at: now).timeIntervalSince1970 * 1_000)
        let secCutoff = Int64(AggregationRules.secondLayerCutoff(at: now).timeIntervalSince1970)
        let minCutoff = Int64(AggregationRules.minuteLayerCutoff(at: now).timeIntervalSince1970)
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM raw_mouse_moves  WHERE ts < ?", arguments: [rawCutoffMs])
            try db.execute(sql: "DELETE FROM raw_mouse_clicks WHERE ts < ?", arguments: [rawCutoffMs])
            try db.execute(sql: "DELETE FROM raw_key_events   WHERE ts < ?", arguments: [rawCutoffMs])
            try db.execute(sql: "DELETE FROM sec_mouse        WHERE ts_second < ?", arguments: [secCutoff])
            try db.execute(sql: "DELETE FROM sec_key          WHERE ts_second < ?", arguments: [secCutoff])
            try db.execute(sql: "DELETE FROM sec_activity     WHERE ts_second < ?", arguments: [secCutoff])
            try db.execute(sql: "DELETE FROM min_mouse        WHERE ts_minute < ?", arguments: [minCutoff])
            try db.execute(sql: "DELETE FROM min_key          WHERE ts_minute < ?", arguments: [minCutoff])
            try db.execute(sql: "DELETE FROM min_app          WHERE ts_minute < ?", arguments: [minCutoff])
            try db.execute(sql: "DELETE FROM min_switches     WHERE ts_minute < ?", arguments: [minCutoff])
            try db.execute(sql: "DELETE FROM min_idle         WHERE ts_minute < ?", arguments: [minCutoff])
        }
    }
}

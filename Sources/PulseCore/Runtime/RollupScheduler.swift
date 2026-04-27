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
        public let foregroundAppToMinInterval: TimeInterval
        public let minAppToHourInterval: TimeInterval
        public let idleEventsToMinInterval: TimeInterval

        public init(
            rawToSecondInterval: TimeInterval = 60,
            secondsToMinutesInterval: TimeInterval = 300,
            minutesToHoursInterval: TimeInterval = 3_600,
            purgeInterval: TimeInterval = 86_400,
            foregroundAppToMinInterval: TimeInterval = 300,
            minAppToHourInterval: TimeInterval = 3_600,
            idleEventsToMinInterval: TimeInterval = 300
        ) {
            self.rawToSecondInterval = rawToSecondInterval
            self.secondsToMinutesInterval = secondsToMinutesInterval
            self.minutesToHoursInterval = minutesToHoursInterval
            self.purgeInterval = purgeInterval
            self.foregroundAppToMinInterval = foregroundAppToMinInterval
            self.minAppToHourInterval = minAppToHourInterval
            self.idleEventsToMinInterval = idleEventsToMinInterval
        }

        public static let `default` = Configuration()
    }

    public enum Job: String, Sendable, Equatable, CaseIterable {
        case rawToSecond
        case secondToMinute
        case minuteToHour
        case foregroundAppToMin
        case minAppToHour
        case idleEventsToMin
        case purgeExpired
    }

    public struct LastRunStamps: Sendable, Equatable {
        public var rawToSecond: Date?
        public var secondToMinute: Date?
        public var minuteToHour: Date?
        public var foregroundAppToMin: Date?
        public var minAppToHour: Date?
        public var idleEventsToMin: Date?
        public var purgeExpired: Date?

        public static let empty = LastRunStamps(
            rawToSecond: nil,
            secondToMinute: nil,
            minuteToHour: nil,
            foregroundAppToMin: nil,
            minAppToHour: nil,
            idleEventsToMin: nil,
            purgeExpired: nil
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
        case .rawToSecond:        try rollRawToSecond(now: now)
        case .secondToMinute:     try rollSecondToMinute(now: now)
        case .minuteToHour:       try rollMinuteToHour(now: now)
        case .foregroundAppToMin: try rollForegroundAppToMin(now: now)
        case .minAppToHour:       try rollMinAppToHour(now: now)
        case .idleEventsToMin:    try rollIdleEventsToMin(now: now)
        case .purgeExpired:       try purgeExpired(now: now)
        }
        lock.lock()
        switch job {
        case .rawToSecond:        lastRuns.rawToSecond = now
        case .secondToMinute:     lastRuns.secondToMinute = now
        case .minuteToHour:       lastRuns.minuteToHour = now
        case .foregroundAppToMin: lastRuns.foregroundAppToMin = now
        case .minAppToHour:       lastRuns.minAppToHour = now
        case .idleEventsToMin:    lastRuns.idleEventsToMin = now
        case .purgeExpired:       lastRuns.purgeExpired = now
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
        case .foregroundAppToMin:
            last = lastRuns.foregroundAppToMin
            interval = configuration.foregroundAppToMinInterval
        case .minAppToHour:
            last = lastRuns.minAppToHour
            interval = configuration.minAppToHourInterval
        case .idleEventsToMin:
            last = lastRuns.idleEventsToMin
            interval = configuration.idleEventsToMinInterval
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
        // Local-midnight-in-UTC bucketing (see `day_mouse_density` comments
        // in V4__mouse_density.sql). `secondsFromGMT(for:)` picks up DST
        // correctly at `now` — rows rolled from wall-clock "yesterday"
        // during a DST transition land in the wall-clock day they were
        // produced, which is what users expect.
        let localOffsetSeconds = Int64(TimeZone.current.secondsFromGMT(for: now))
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

            // F-04 / B9: fold rolled coordinates into a 128×128 density bin
            // keyed by (local day, display). Runs **before** the DELETE below
            // because the raw rows are this step's only data source. The
            // 128-cell grid is the MouseTrajectoryGrid.size constant; the
            // clamps guard the x_norm = 1.0 edge so `CAST(1.0 * 128 AS INTEGER)
            // = 128` maps to bin 127, not out-of-bounds.
            try db.execute(sql: """
                INSERT INTO day_mouse_density (day, display_id, bin_x, bin_y, count)
                SELECT
                    (((ts / 1000 + ?) / 86400) * 86400) - ? AS day,
                    display_id,
                    MIN(127, MAX(0, CAST(x_norm * 128 AS INTEGER))) AS bin_x,
                    MIN(127, MAX(0, CAST(y_norm * 128 AS INTEGER))) AS bin_y,
                    COUNT(*) AS count
                FROM raw_mouse_moves
                WHERE ts < ?
                GROUP BY day, display_id, bin_x, bin_y
                ON CONFLICT(day, display_id, bin_x, bin_y) DO UPDATE SET
                    count = day_mouse_density.count + excluded.count
                """, arguments: [localOffsetSeconds, localOffsetSeconds, cutoffMillis])

            // F-16: same shape as the move-density fold above, but
            // sourced from `raw_mouse_clicks`. Each row contributes 1
            // to the cell containing its (x_norm, y_norm). Same 128×128
            // grid + same edge clamp + same local-day bucketing so the
            // F-04 renderer + `MouseDisplayHistogram` shape carries
            // through unchanged on the read side.
            try db.execute(sql: """
                INSERT INTO day_click_density (day, display_id, bin_x, bin_y, count)
                SELECT
                    (((ts / 1000 + ?) / 86400) * 86400) - ? AS day,
                    display_id,
                    MIN(127, MAX(0, CAST(x_norm * 128 AS INTEGER))) AS bin_x,
                    MIN(127, MAX(0, CAST(y_norm * 128 AS INTEGER))) AS bin_y,
                    COUNT(*) AS count
                FROM raw_mouse_clicks
                WHERE ts < ?
                GROUP BY day, display_id, bin_x, bin_y
                ON CONFLICT(day, display_id, bin_x, bin_y) DO UPDATE SET
                    count = day_click_density.count + excluded.count
                """, arguments: [localOffsetSeconds, localOffsetSeconds, cutoffMillis])

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

            // F-33 — sec_shortcuts → min_shortcuts. Group by
            // (minute, combo) so every combo survives the rollup
            // independently; the ORDER of combos doesn't matter.
            try db.execute(sql: """
                INSERT INTO min_shortcuts (ts_minute, combo, count)
                SELECT (ts_second / 60) * 60, combo, SUM(count)
                FROM sec_shortcuts
                WHERE ts_second < ?
                GROUP BY ts_second / 60, combo
                ON CONFLICT(ts_minute, combo) DO UPDATE SET
                    count = min_shortcuts.count + excluded.count
                """, arguments: [cutoffSeconds])

            try db.execute(sql: "DELETE FROM sec_mouse WHERE ts_second < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM sec_key WHERE ts_second < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM sec_shortcuts WHERE ts_second < ?", arguments: [cutoffSeconds])
        }
    }

    private func rollMinuteToHour(now: Date) throws {
        let cutoffSeconds = Int64(AggregationRules.hourBucket(for: now).timeIntervalSince1970)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                SELECT (mm.ts_minute / 3600) * 3600,
                       COALESCE(SUM(mk.press_count), 0),
                       COALESCE(SUM(mm.distance_mm), 0.0),
                       COALESCE(SUM(mm.click_events), 0),
                       0,
                       COALESCE(SUM(mm.scroll_ticks), 0)
                FROM min_mouse mm
                LEFT JOIN min_key mk ON mk.ts_minute = mm.ts_minute
                WHERE mm.ts_minute < ?
                GROUP BY mm.ts_minute / 3600
                ON CONFLICT(ts_hour) DO UPDATE SET
                    key_press_total   = hour_summary.key_press_total   + excluded.key_press_total,
                    mouse_distance_mm = hour_summary.mouse_distance_mm + excluded.mouse_distance_mm,
                    mouse_click_total = hour_summary.mouse_click_total + excluded.mouse_click_total,
                    scroll_ticks      = hour_summary.scroll_ticks      + excluded.scroll_ticks
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

            // F-33 — min_shortcuts → hour_shortcuts, same pattern.
            try db.execute(sql: """
                INSERT INTO hour_shortcuts (ts_hour, combo, count)
                SELECT (ts_minute / 3600) * 3600, combo, SUM(count)
                FROM min_shortcuts
                WHERE ts_minute < ?
                GROUP BY ts_minute / 3600, combo
                ON CONFLICT(ts_hour, combo) DO UPDATE SET
                    count = hour_shortcuts.count + excluded.count
                """, arguments: [cutoffSeconds])

            try db.execute(sql: "DELETE FROM min_mouse WHERE ts_minute < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM min_key WHERE ts_minute < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM min_idle WHERE ts_minute < ?", arguments: [cutoffSeconds])
            try db.execute(sql: "DELETE FROM min_shortcuts WHERE ts_minute < ?", arguments: [cutoffSeconds])
        }
    }

    /// Walks `foreground_app` switches written into `system_events` and
    /// credits seconds of usage to each containing minute-bucket in
    /// `min_app`. Unlike the mouse/key rollups, the source (`system_events`)
    /// has permanent retention, so we cannot delete processed rows; a
    /// watermark in `rollup_watermarks` tracks the last-processed upper
    /// bound instead.
    ///
    /// The bundle active at the watermark boundary is carried forward via
    /// a synthetic leading switch at `watermarkMs` so its share of the
    /// first processed minute isn't dropped.
    private func rollForegroundAppToMin(now: Date) throws {
        let minuteCutoffSec = Int64(AggregationRules.minuteBucket(for: now).timeIntervalSince1970)
        let minuteCutoffMs = minuteCutoffSec * 1_000

        try database.queue.write { db in
            let watermarkMs = try Int64.fetchOne(
                db,
                sql: "SELECT last_processed_ms FROM rollup_watermarks WHERE job = 'foreground_app_to_min'"
            ) ?? 0
            guard watermarkMs < minuteCutoffMs else { return }

            // Bundle active at the watermark boundary (if any). Without it
            // the interval from watermark → first in-range switch would be
            // attributed to "nothing".
            let priorBundle: String? = try String.fetchOne(db, sql: """
                SELECT payload FROM system_events
                WHERE category = 'foreground_app' AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [watermarkMs])

            let inRangeRows = try Row.fetchAll(db, sql: """
                SELECT ts, payload FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [watermarkMs, minuteCutoffMs])

            var switches: [(Int64, String)] = []
            if let priorBundle {
                switches.append((watermarkMs, priorBundle))
            }
            for row in inRangeRows {
                let ts: Int64 = row["ts"]
                let bundle: String = row["payload"]
                switches.append((ts, bundle))
            }

            // Attribute each interval's seconds to containing minute buckets.
            var byMinute: [Int64: [String: Int64]] = [:]
            for index in 0..<switches.count {
                let (startMs, bundle) = switches[index]
                let endMs: Int64 = index + 1 < switches.count
                    ? switches[index + 1].0
                    : minuteCutoffMs
                addSecondsPerMinute(
                    startMs: startMs,
                    endMs: endMs,
                    bundle: bundle,
                    into: &byMinute
                )
            }

            for (minute, bundles) in byMinute {
                for (bundle, seconds) in bundles where seconds > 0 {
                    try db.execute(sql: """
                        INSERT INTO min_app (ts_minute, bundle_id, seconds_used)
                        VALUES (?, ?, ?)
                        ON CONFLICT(ts_minute, bundle_id) DO UPDATE SET
                            seconds_used = min_app.seconds_used + excluded.seconds_used
                        """, arguments: [minute, bundle, seconds])
                }
            }

            // min_switches — count how many foreground_app switches
            // landed in each minute. Uses the same watermark window, so
            // the per-minute count is incremented by the exact number of
            // in-range switches even if they're spread across many
            // bundles. Synthetic priorBundle doesn't participate (it's
            // not an actual switch, only a boundary marker).
            try db.execute(sql: """
                INSERT INTO min_switches (ts_minute, app_switch_count)
                SELECT ((ts / 1000) / 60) * 60, COUNT(*)
                FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                GROUP BY ((ts / 1000) / 60) * 60
                ON CONFLICT(ts_minute) DO UPDATE SET
                    app_switch_count = min_switches.app_switch_count + excluded.app_switch_count
                """, arguments: [watermarkMs, minuteCutoffMs])

            // Advance the watermark unconditionally, even if no switches
            // landed — skipping an empty window should still move time
            // forward so we don't re-scan the same empty range next tick.
            try db.execute(sql: """
                INSERT INTO rollup_watermarks (job, last_processed_ms)
                VALUES ('foreground_app_to_min', ?)
                ON CONFLICT(job) DO UPDATE SET last_processed_ms = excluded.last_processed_ms
                """, arguments: [minuteCutoffMs])
        }
    }

    /// Splits the half-open millisecond interval `[startMs, endMs)` into
    /// minute buckets and credits `seconds` to each entry of `byMinute`.
    private func addSecondsPerMinute(
        startMs: Int64,
        endMs: Int64,
        bundle: String,
        into byMinute: inout [Int64: [String: Int64]]
    ) {
        guard endMs > startMs else { return }
        let startSec = startMs / 1_000
        let endSec = endMs / 1_000
        guard endSec > startSec else { return }

        var cursor = startSec
        while cursor < endSec {
            let minuteBucket = (cursor / 60) * 60
            let nextBoundary = minuteBucket + 60
            let segEnd = min(endSec, nextBoundary)
            let segSeconds = segEnd - cursor
            byMinute[minuteBucket, default: [:]][bundle, default: 0] += segSeconds
            cursor = segEnd
        }
    }

    /// Promotes closed `min_app` rows to `hour_app`. Like the mouse / key
    /// rollup, the min layer is deleted after promotion; `purgeExpired`
    /// retention targets the source table for anything that survives.
    private func rollMinAppToHour(now: Date) throws {
        let hourCutoffSec = Int64(AggregationRules.hourBucket(for: now).timeIntervalSince1970)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_app (ts_hour, bundle_id, seconds_used)
                SELECT (ts_minute / 3600) * 3600, bundle_id, SUM(seconds_used)
                FROM min_app
                WHERE ts_minute < ?
                GROUP BY (ts_minute / 3600) * 3600, bundle_id
                ON CONFLICT(ts_hour, bundle_id) DO UPDATE SET
                    seconds_used = hour_app.seconds_used + excluded.seconds_used
                """, arguments: [hourCutoffSec])

            try db.execute(
                sql: "DELETE FROM min_app WHERE ts_minute < ?",
                arguments: [hourCutoffSec]
            )
        }
    }

    /// Walks `idle_entered` / `idle_exited` transitions in `system_events`
    /// and credits each idle interval's seconds to its containing
    /// minute-bucket in `min_idle`. Same watermark + priorState pattern as
    /// the foreground-app rollup: if the user was already idle at the
    /// watermark boundary we open a synthetic interval at the watermark
    /// and let it close on the next `idle_exited`. If the idle state is
    /// still open at the minute cutoff we close the interval there
    /// (the next tick will re-open it if the transition hasn't arrived).
    private func rollIdleEventsToMin(now: Date) throws {
        let minuteCutoffSec = Int64(AggregationRules.minuteBucket(for: now).timeIntervalSince1970)
        let minuteCutoffMs = minuteCutoffSec * 1_000

        try database.queue.write { db in
            let watermarkMs = try Int64.fetchOne(
                db,
                sql: "SELECT last_processed_ms FROM rollup_watermarks WHERE job = 'idle_events_to_min'"
            ) ?? 0
            guard watermarkMs < minuteCutoffMs else { return }

            // Was the user idle at the watermark boundary?
            let priorCategory: String? = try String.fetchOne(db, sql: """
                SELECT category FROM system_events
                WHERE category IN ('idle_entered', 'idle_exited') AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [watermarkMs])
            let startedIdle = (priorCategory == "idle_entered")

            let transitionRows = try Row.fetchAll(db, sql: """
                SELECT ts, category FROM system_events
                WHERE category IN ('idle_entered', 'idle_exited') AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [watermarkMs, minuteCutoffMs])

            var intervals: [(Int64, Int64)] = []
            var idleStart: Int64? = startedIdle ? watermarkMs : nil
            for row in transitionRows {
                let ts: Int64 = row["ts"]
                let category: String = row["category"]
                if category == "idle_entered" {
                    if idleStart == nil {
                        idleStart = ts
                    }
                } else {
                    if let start = idleStart {
                        intervals.append((start, ts))
                        idleStart = nil
                    }
                }
            }
            // Still idle at the cutoff → close the open interval at the
            // cutoff. The next tick's priorState will reopen it if the
            // exit hasn't happened by then.
            if let start = idleStart {
                intervals.append((start, minuteCutoffMs))
            }

            var byMinute: [Int64: Int64] = [:]
            for (startMs, endMs) in intervals {
                addIdleSecondsPerMinute(startMs: startMs, endMs: endMs, into: &byMinute)
            }

            for (minute, seconds) in byMinute where seconds > 0 {
                try db.execute(sql: """
                    INSERT INTO min_idle (ts_minute, idle_seconds)
                    VALUES (?, ?)
                    ON CONFLICT(ts_minute) DO UPDATE SET
                        idle_seconds = min_idle.idle_seconds + excluded.idle_seconds
                    """, arguments: [minute, seconds])
            }

            try db.execute(sql: """
                INSERT INTO rollup_watermarks (job, last_processed_ms)
                VALUES ('idle_events_to_min', ?)
                ON CONFLICT(job) DO UPDATE SET last_processed_ms = excluded.last_processed_ms
                """, arguments: [minuteCutoffMs])
        }
    }

    /// Flat-bucket variant of `addSecondsPerMinute` — idle time is
    /// attributed to a single scalar per minute (not nested by bundle).
    private func addIdleSecondsPerMinute(
        startMs: Int64,
        endMs: Int64,
        into byMinute: inout [Int64: Int64]
    ) {
        guard endMs > startMs else { return }
        let startSec = startMs / 1_000
        let endSec = endMs / 1_000
        guard endSec > startSec else { return }
        var cursor = startSec
        while cursor < endSec {
            let minuteBucket = (cursor / 60) * 60
            let nextBoundary = minuteBucket + 60
            let segEnd = min(endSec, nextBoundary)
            byMinute[minuteBucket, default: 0] += (segEnd - cursor)
            cursor = segEnd
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
            try db.execute(sql: "DELETE FROM sec_shortcuts    WHERE ts_second < ?", arguments: [secCutoff])
            try db.execute(sql: "DELETE FROM min_shortcuts    WHERE ts_minute < ?", arguments: [minCutoff])
            // hour_shortcuts has permanent retention like hour_summary.
        }
    }
}

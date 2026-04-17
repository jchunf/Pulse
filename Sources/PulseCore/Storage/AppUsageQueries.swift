import Foundation
import GRDB

/// Read-side aggregation queries used by the Dashboard. These run against
/// the L1/L2 tables for low-latency scans (the production rollup keeps them
/// up to date) and against `system_events` for the foreground-app interval
/// derivation (rollup → `min_app` is a follow-up; today the foreground
/// changes live only as point events in `system_events`).
public extension EventStore {

    // MARK: - Today summary

    /// Roll-up of activity within `[start, end)` capped at `capUntil`. The
    /// cap is for "today is in progress" — the latest app's runtime should
    /// extend only to "now", not to the end of the day.
    func todaySummary(
        start: Date,
        end: Date,
        capUntil: Date
    ) throws -> TodaySummary {
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        let startSec = Int64(start.timeIntervalSince1970)
        let endSec = Int64(end.timeIntervalSince1970)

        return try database.queue.read { db -> TodaySummary in
            // The rollups are destructive: rollMinuteToHour deletes from
            // min_*; rollSecondToMinute deletes from sec_*; rollRawToSecond
            // deletes from raw_*. Any given (minute, second, ms) event
            // therefore lives in exactly **one** of the layers at a time,
            // so UNIONing the four layers over the same date range is
            // correct regardless of rollup progress.

            // L3 — closed hours promoted to hour_summary.
            let mouseDistanceHour = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(mouse_distance_mm), 0.0) FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseClicksHour = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(mouse_click_total), 0) FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [startSec, endSec]) ?? 0
            let keyPressesHour = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(key_press_total), 0) FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [startSec, endSec]) ?? 0

            // L2 — closed minutes not yet promoted.
            let mouseDistanceMin = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(distance_mm), 0.0) FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseClicksMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(click_events), 0) FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let keyPressesMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(press_count), 0) FROM min_key
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0

            // L1 — closed seconds not yet promoted.
            let mouseDistanceSec = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(distance_mm), 0.0) FROM sec_mouse
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseClicksSec = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(click_events), 0) FROM sec_mouse
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0
            let keyPressesSec = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(press_count), 0) FROM sec_key
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0

            // L0 — raw rows not yet promoted.
            let rawMoves = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_mouse_moves WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
            let rawClicks = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_mouse_clicks WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
            let rawKeys = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_key_events WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0

            // Idle seconds — rolled L3 (hour_summary) + un-rolled L2
            // (min_idle). `idle_events_to_min` rollup (B6) is the
            // producer for both layers; a pre-rollup install will read
            // zero here, same deliberate staleness the trend + heatmap
            // charts accept.
            let idleHour = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(idle_seconds), 0) FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [startSec, endSec]) ?? 0
            let idleMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(idle_seconds), 0) FROM min_idle
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0

            // Scroll ticks — same L3 + L2 + L1 layering as mouse clicks.
            let scrollsHour = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(scroll_ticks), 0) FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [startSec, endSec]) ?? 0
            let scrollsMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(scroll_ticks), 0) FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let scrollsSec = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(scroll_ticks), 0) FROM sec_mouse
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0

            // App ranking — run the interval query then sum its result.
            let topApps = try Self.runAppUsageQuery(
                db: db,
                startMs: startMs,
                endMs: endMs,
                capMs: Int64(capUntil.timeIntervalSince1970 * 1_000),
                limit: 5
            )
            let totalActiveSeconds = topApps.reduce(0) { $0 + $1.secondsUsed }

            return TodaySummary(
                totalKeyPresses: keyPressesHour + keyPressesMin + keyPressesSec + rawKeys,
                totalMouseClicks: mouseClicksHour + mouseClicksMin + mouseClicksSec + rawClicks,
                totalMouseMovesRaw: rawMoves,
                totalMouseDistanceMillimeters: mouseDistanceHour + mouseDistanceMin + mouseDistanceSec,
                totalScrollTicks: scrollsHour + scrollsMin + scrollsSec,
                totalActiveSeconds: totalActiveSeconds,
                totalIdleSeconds: idleHour + idleMin,
                topApps: topApps
            )
        }
    }

    // MARK: - App usage ranking

    /// Returns app usage in `[start, end)`, capped at `capUntil` for the
    /// last open interval. Sorted by seconds-used descending.
    func appUsageRanking(
        start: Date,
        end: Date,
        capUntil: Date,
        limit: Int = 10
    ) throws -> [AppUsageRow] {
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        let capMs = Int64(capUntil.timeIntervalSince1970 * 1_000)
        return try database.queue.read { db in
            try Self.runAppUsageQuery(
                db: db,
                startMs: startMs,
                endMs: endMs,
                capMs: capMs,
                limit: limit
            )
        }
    }

    /// Computes app-usage seconds per bundle over `[startMs, endMs)` by
    /// layering the three non-overlapping sources populated by the B5
    /// rollup pipeline:
    ///
    /// - `hour_app` for fully-rolled hours (L3).
    /// - `min_app` for rolled minutes in the currently-open hour (L2).
    /// - `system_events` (LEAD over raw switches) for the portion beyond
    ///   the `foreground_app_to_min` watermark, capped at `capMs`.
    ///
    /// The rolled sources are deleted at each promotion step, so UNIONing
    /// all three over the same range never double-counts. When no rollup
    /// has run yet (fresh install) the watermark is 0 and the whole
    /// window resolves to the LEAD-based raw path — which still honours
    /// cross-range continuity via `priorBundle` before the range start.
    static func runAppUsageQuery(
        db: Database,
        startMs: Int64,
        endMs: Int64,
        capMs: Int64,
        limit: Int
    ) throws -> [AppUsageRow] {
        let effectiveCapMs = min(capMs, endMs)

        let watermarkMs = try Int64.fetchOne(
            db,
            sql: "SELECT last_processed_ms FROM rollup_watermarks WHERE job = 'foreground_app_to_min'"
        ) ?? 0

        var byBundle: [String: Int64] = [:]

        // Rolled portion: [startMs, min(watermarkMs, endMs)).
        let rolledEndMs = min(watermarkMs, endMs)
        if rolledEndMs > startMs {
            let startSec = startMs / 1_000
            let rolledEndSec = rolledEndMs / 1_000
            for row in try Row.fetchAll(db, sql: """
                SELECT bundle_id, COALESCE(SUM(seconds_used), 0) AS seconds_used FROM hour_app
                WHERE ts_hour >= ? AND ts_hour < ?
                GROUP BY bundle_id
                """, arguments: [startSec, rolledEndSec]) {
                byBundle[row["bundle_id"], default: 0] += row["seconds_used"] as Int64
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT bundle_id, COALESCE(SUM(seconds_used), 0) AS seconds_used FROM min_app
                WHERE ts_minute >= ? AND ts_minute < ?
                GROUP BY bundle_id
                """, arguments: [startSec, rolledEndSec]) {
                byBundle[row["bundle_id"], default: 0] += row["seconds_used"] as Int64
            }
        }

        // Raw portion: [max(startMs, watermarkMs), effectiveCapMs).
        let rawStartMs = max(startMs, watermarkMs)
        if rawStartMs < effectiveCapMs {
            for (bundle, seconds) in try rawPortionSeconds(
                db: db,
                startMs: rawStartMs,
                endMs: endMs,
                capMs: effectiveCapMs
            ) {
                byBundle[bundle, default: 0] += seconds
            }
        }

        return byBundle
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { AppUsageRow(bundleId: $0.key, secondsUsed: Int($0.value)) }
    }

    /// LEAD-over-`system_events` computation for the portion of the range
    /// that hasn't yet been rolled into `min_app`. Extracted so the rolled
    /// path above can call it cleanly. A synthetic leading switch at
    /// `startMs` carries whichever bundle was active just before the
    /// range, so cross-boundary continuity is preserved.
    private static func rawPortionSeconds(
        db: Database,
        startMs: Int64,
        endMs: Int64,
        capMs: Int64
    ) throws -> [String: Int64] {
        let priorBundle = try String.fetchOne(db, sql: """
            SELECT payload FROM system_events
            WHERE category = 'foreground_app' AND ts < ?
            ORDER BY ts DESC LIMIT 1
            """, arguments: [startMs])

        let preamble: String
        var arguments: [(any DatabaseValueConvertible)?]
        if let priorBundle {
            preamble = """
                WITH switches AS (
                    SELECT ? AS ts, ? AS bundle_id
                    UNION ALL
                    SELECT ts, payload AS bundle_id FROM system_events
                    WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                )
                """
            arguments = [startMs, priorBundle, startMs, endMs]
        } else {
            preamble = """
                WITH switches AS (
                    SELECT ts, payload AS bundle_id FROM system_events
                    WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                )
                """
            arguments = [startMs, endMs]
        }

        let sql = preamble + """

            , ordered AS (
                SELECT ts, bundle_id,
                       LEAD(ts, 1, ?) OVER (ORDER BY ts) AS next_ts
                FROM switches
            )
            SELECT bundle_id,
                   SUM(MAX(0, MIN(next_ts, ?) - ts)) / 1000 AS seconds_used
            FROM ordered
            GROUP BY bundle_id
            HAVING seconds_used > 0
            """
        let tail: [(any DatabaseValueConvertible)?] = [capMs, capMs]
        arguments.append(contentsOf: tail)

        var result: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) {
            let bundle: String = row["bundle_id"]
            let seconds: Int64 = row["seconds_used"]
            result[bundle] = seconds
        }
        return result
    }

    // MARK: - Daily trend

    /// Returns one `DailyTrendPoint` per calendar day in the `days`-day
    /// window ending at `endingAt`. Days with no rolled-up activity get a
    /// zero-filled point so the returned array is always `days` long and
    /// the UI chart has a continuous x-axis. Source table is `hour_summary`
    /// (L3), same staleness caveat as `hourlyHeatmap` — the in-progress
    /// hour is not reflected until it rolls up.
    ///
    /// Points are ordered oldest → newest so a LineMark reads left to right.
    func dailyTrend(
        endingAt: Date,
        days: Int,
        calendar: Calendar = .current
    ) throws -> [DailyTrendPoint] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
            return []
        }
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            return []
        }
        let rangeStartSec = Int64(startDay.timeIntervalSince1970)
        let rangeEndSec = Int64(rangeEnd.timeIntervalSince1970)

        let rows = try database.queue.read { db -> [(Int64, Int, Double, Int, Int, Int)] in
            try Row.fetchAll(db, sql: """
                SELECT ts_hour,
                       key_press_total,
                       mouse_distance_mm,
                       mouse_click_total,
                       scroll_ticks,
                       idle_seconds
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [rangeStartSec, rangeEndSec]).map { row in
                (
                    row["ts_hour"] as Int64,
                    row["key_press_total"] as Int,
                    row["mouse_distance_mm"] as Double,
                    row["mouse_click_total"] as Int,
                    row["scroll_ticks"] as Int,
                    row["idle_seconds"] as Int
                )
            }
        }

        // Aggregate hourly rows into per-day buckets.
        struct DayAgg {
            var keys: Int = 0
            var distance: Double = 0
            var clicks: Int = 0
            var scrolls: Int = 0
            var idle: Int = 0
        }
        var buckets: [Int: DayAgg] = [:]
        for (tsHour, keys, distance, clicks, scrolls, idle) in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(tsHour))
            let dayStart = calendar.startOfDay(for: date)
            guard let daysFromStart = calendar.dateComponents([.day], from: startDay, to: dayStart).day else {
                continue
            }
            var agg = buckets[daysFromStart] ?? DayAgg()
            agg.keys += keys
            agg.distance += distance
            agg.clicks += clicks
            agg.scrolls += scrolls
            agg.idle += idle
            buckets[daysFromStart] = agg
        }

        // Emit points for every day in the window, padding zeros.
        return (0..<days).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index, to: startDay) else { return nil }
            let agg = buckets[index] ?? DayAgg()
            return DailyTrendPoint(
                day: day,
                keyPresses: agg.keys,
                mouseClicks: agg.clicks,
                mouseDistanceMillimeters: agg.distance,
                scrollTicks: agg.scrolls,
                idleSeconds: agg.idle
            )
        }
    }

    // MARK: - Hourly heatmap

    /// Returns one `HeatmapCell` per hour with non-zero activity in the
    /// `days` days ending at `endingAt`. `activityCount` = key presses +
    /// mouse clicks in the hour. Read from `hour_summary` (L3). The
    /// current in-progress hour is **not** reflected — it's still being
    /// accumulated in `min_*` / `sec_*` / raw tables and only rolls into
    /// `hour_summary` once the hour is complete. The 1-hour staleness is
    /// acceptable for a 7-day pattern visualization.
    ///
    /// `dayOffset` is 0 for today, `days - 1` for the oldest included day.
    func hourlyHeatmap(
        endingAt: Date,
        days: Int,
        calendar: Calendar = .current
    ) throws -> [HeatmapCell] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
            return []
        }
        let rangeStartSec = Int64(startDay.timeIntervalSince1970)
        // Include the entire current day so the heatmap's rightmost column
        // shows today's completed hours too.
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            return []
        }
        let rangeEndSec = Int64(rangeEnd.timeIntervalSince1970)

        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ts_hour,
                       (key_press_total + mouse_click_total) AS activity
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                  AND (key_press_total + mouse_click_total) > 0
                ORDER BY ts_hour
                """, arguments: [rangeStartSec, rangeEndSec])
            return rows.compactMap { row -> HeatmapCell? in
                let tsHour: Int64 = row["ts_hour"]
                let activity: Int = row["activity"]
                let date = Date(timeIntervalSince1970: TimeInterval(tsHour))
                let dayOfDate = calendar.startOfDay(for: date)
                guard let daysFromStart = calendar.dateComponents([.day], from: startDay, to: dayOfDate).day else {
                    return nil
                }
                let dayOffset = (days - 1) - daysFromStart
                let hour = calendar.component(.hour, from: date)
                return HeatmapCell(dayOffset: dayOffset, hour: hour, activityCount: activity)
            }
        }
    }

    // MARK: - Longest focus segment (A16)

    /// Returns today's longest uninterrupted run of the user in a single
    /// foreground app while not being idle — the "deep focus" streak the
    /// review (`reviews/2026-04-17-product-direction.md#22`) flags as the
    /// single most under-leveraged signal we already collect.
    ///
    /// The heuristic: walk `system_events.foreground_app` transitions
    /// for the day, and for each `(bundle, start, end)` interval check
    /// whether every minute in it had ≥ `minActiveSecondsPerMinute` active
    /// seconds (derived from `min_idle` as `60 - idle_seconds`). Segments
    /// containing any sub-threshold minute are discarded. Among the
    /// surviving segments, the longest one wins (ties broken by earlier
    /// start time for determinism).
    ///
    /// Returns `nil` when no segment qualifies (fresh install, pre-rollup,
    /// or a day dominated by context switches).
    func longestFocusSegment(
        on day: Date,
        minActiveSecondsPerMinute: Int = 30,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> FocusSegment? {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart, now)
        guard dayEnd > dayStart else { return nil }
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let dayEndMs = Int64(dayEnd.timeIntervalSince1970 * 1_000)
        let dayStartSec = Int64(dayStart.timeIntervalSince1970)
        let dayEndSec = Int64(dayEnd.timeIntervalSince1970)

        return try database.queue.read { db -> FocusSegment? in
            // Idle seconds per minute for the day. A minute is "active
            // enough" when (60 - idle_seconds) >= minActiveSecondsPerMinute.
            let idleRows = try Row.fetchAll(db, sql: """
                SELECT ts_minute, idle_seconds FROM min_idle
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [dayStartSec, dayEndSec])
            var idleByMinute: [Int64: Int64] = [:]
            for row in idleRows {
                idleByMinute[row["ts_minute"] as Int64] = row["idle_seconds"] as Int64
            }
            func minuteIsActive(_ minuteStartSec: Int64) -> Bool {
                let idle = idleByMinute[minuteStartSec] ?? 0
                return (60 - idle) >= Int64(minActiveSecondsPerMinute)
            }

            // The bundle active at day start (carry-over from yesterday).
            let priorBundle = try String.fetchOne(db, sql: """
                SELECT payload FROM system_events
                WHERE category = 'foreground_app' AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [dayStartMs])

            // In-range transitions.
            let transitions = try Row.fetchAll(db, sql: """
                SELECT ts, payload FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [dayStartMs, dayEndMs])

            // Assemble intervals: [(startMs, endMs, bundle)].
            var intervals: [(Int64, Int64, String)] = []
            var currentStart = dayStartMs
            var currentBundle: String? = priorBundle
            for row in transitions {
                let ts: Int64 = row["ts"]
                let bundle: String = row["payload"]
                if let prior = currentBundle, ts > currentStart {
                    intervals.append((currentStart, ts, prior))
                }
                currentStart = ts
                currentBundle = bundle
            }
            if let prior = currentBundle, dayEndMs > currentStart {
                intervals.append((currentStart, dayEndMs, prior))
            }

            // For each interval, verify every minute it covers is active
            // (meets the per-minute threshold). Keep the longest qualifier.
            var best: FocusSegment?
            for (startMs, endMs, bundle) in intervals {
                let durationSeconds = (endMs - startMs) / 1_000
                if durationSeconds < 60 { continue } // <1 min can't be focus
                let firstMinuteStart = (startMs / 1_000 / 60) * 60
                let lastMinuteStartExclusive = ((endMs + 59_999) / 1_000 / 60) * 60
                var minuteCursor = firstMinuteStart
                var allActive = true
                while minuteCursor < lastMinuteStartExclusive {
                    if !minuteIsActive(minuteCursor) {
                        allActive = false
                        break
                    }
                    minuteCursor += 60
                }
                guard allActive else { continue }
                let candidate = FocusSegment(
                    bundleId: bundle,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(startMs) / 1_000),
                    endedAt: Date(timeIntervalSince1970: TimeInterval(endMs) / 1_000),
                    durationSeconds: Int(durationSeconds)
                )
                if let current = best {
                    if candidate.durationSeconds > current.durationSeconds {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
            return best
        }
    }
}

// MARK: - Value types

public struct TodaySummary: Sendable, Equatable {
    public let totalKeyPresses: Int
    public let totalMouseClicks: Int
    public let totalMouseMovesRaw: Int
    public let totalMouseDistanceMillimeters: Double
    public let totalScrollTicks: Int
    public let totalActiveSeconds: Int
    public let totalIdleSeconds: Int
    public let topApps: [AppUsageRow]

    public init(
        totalKeyPresses: Int,
        totalMouseClicks: Int,
        totalMouseMovesRaw: Int,
        totalMouseDistanceMillimeters: Double,
        totalScrollTicks: Int,
        totalActiveSeconds: Int,
        totalIdleSeconds: Int,
        topApps: [AppUsageRow]
    ) {
        self.totalKeyPresses = totalKeyPresses
        self.totalMouseClicks = totalMouseClicks
        self.totalMouseMovesRaw = totalMouseMovesRaw
        self.totalMouseDistanceMillimeters = totalMouseDistanceMillimeters
        self.totalScrollTicks = totalScrollTicks
        self.totalActiveSeconds = totalActiveSeconds
        self.totalIdleSeconds = totalIdleSeconds
        self.topApps = topApps
    }
}

public struct AppUsageRow: Sendable, Equatable, Identifiable {
    public let bundleId: String
    public let secondsUsed: Int

    public var id: String { bundleId }

    public init(bundleId: String, secondsUsed: Int) {
        self.bundleId = bundleId
        self.secondsUsed = secondsUsed
    }
}

/// One cell of a 24h × Nd activity heatmap. `dayOffset` 0 = today, 1 =
/// yesterday, … The producing query only emits cells with non-zero
/// activity; UI layers should default missing `(dayOffset, hour)`
/// combinations to zero.
/// One calendar day's activity totals, used by the weekly trend chart.
/// `keyPresses` + `mouseClicks` are count metrics; `mouseDistanceMillimeters`
/// is the physical-distance total used by the mileage storyline.
public struct DailyTrendPoint: Sendable, Equatable, Identifiable {
    public let day: Date
    public let keyPresses: Int
    public let mouseClicks: Int
    public let mouseDistanceMillimeters: Double
    public let scrollTicks: Int
    public let idleSeconds: Int

    public var id: TimeInterval { day.timeIntervalSince1970 }

    public init(
        day: Date,
        keyPresses: Int,
        mouseClicks: Int,
        mouseDistanceMillimeters: Double,
        scrollTicks: Int = 0,
        idleSeconds: Int = 0
    ) {
        self.day = day
        self.keyPresses = keyPresses
        self.mouseClicks = mouseClicks
        self.mouseDistanceMillimeters = mouseDistanceMillimeters
        self.scrollTicks = scrollTicks
        self.idleSeconds = idleSeconds
    }

    /// Convenience: total "intentional event" count for single-metric charts.
    public var totalEvents: Int { keyPresses + mouseClicks }
}

public struct HeatmapCell: Sendable, Equatable {
    public let dayOffset: Int
    public let hour: Int
    public let activityCount: Int

    public init(dayOffset: Int, hour: Int, activityCount: Int) {
        self.dayOffset = dayOffset
        self.hour = hour
        self.activityCount = activityCount
    }
}

/// One uninterrupted run of the user in a single foreground app while
/// staying active (not idle). Produced by
/// `EventStore.longestFocusSegment(on:)` and rendered by `DeepFocusCard`.
/// `durationSeconds` is carried separately rather than derived from
/// `endedAt - startedAt` so callers can persist / log the value without
/// re-doing the Date math.
public struct FocusSegment: Sendable, Equatable {
    public let bundleId: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Int

    public init(bundleId: String, startedAt: Date, endedAt: Date, durationSeconds: Int) {
        self.bundleId = bundleId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
    }
}

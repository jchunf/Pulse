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
                totalActiveSeconds: totalActiveSeconds,
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

    /// Builds app-usage rows by deriving intervals from foreground_app
    /// system_events. Uses LEAD() to compute each interval's end as the
    /// next switch, falling back to `capMs` for the latest switch.
    ///
    /// Cross-day continuity (an app active before `start`): if the latest
    /// switch before `start` is not nil, prepend a synthetic switch at
    /// `start` for that bundle so its share of the queried range counts.
    static func runAppUsageQuery(
        db: Database,
        startMs: Int64,
        endMs: Int64,
        capMs: Int64,
        limit: Int
    ) throws -> [AppUsageRow] {
        // Find the bundle active just before the queried range, if any.
        let priorBundle = try String.fetchOne(db, sql: """
            SELECT payload FROM system_events
            WHERE category = 'foreground_app' AND ts < ?
            ORDER BY ts DESC LIMIT 1
            """, arguments: [startMs])

        // Build the SELECT carrying all switches in range. If we have a
        // prior bundle, prepend a synthetic switch at exactly `start`.
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
            ORDER BY seconds_used DESC
            LIMIT ?
            """

        let tail: [(any DatabaseValueConvertible)?] = [capMs, capMs, limit]
        arguments.append(contentsOf: tail)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            AppUsageRow(
                bundleId: row["bundle_id"],
                secondsUsed: row["seconds_used"]
            )
        }
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

        let rows = try database.queue.read { db -> [(Int64, Int, Double, Int)] in
            try Row.fetchAll(db, sql: """
                SELECT ts_hour,
                       key_press_total,
                       mouse_distance_mm,
                       mouse_click_total
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [rangeStartSec, rangeEndSec]).map { row in
                (
                    row["ts_hour"] as Int64,
                    row["key_press_total"] as Int,
                    row["mouse_distance_mm"] as Double,
                    row["mouse_click_total"] as Int
                )
            }
        }

        // Aggregate hourly rows into per-day buckets.
        var buckets: [Int: (keys: Int, distance: Double, clicks: Int)] = [:]
        for (tsHour, keys, distance, clicks) in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(tsHour))
            let dayStart = calendar.startOfDay(for: date)
            guard let daysFromStart = calendar.dateComponents([.day], from: startDay, to: dayStart).day else {
                continue
            }
            let current = buckets[daysFromStart] ?? (0, 0.0, 0)
            buckets[daysFromStart] = (
                keys: current.keys + keys,
                distance: current.distance + distance,
                clicks: current.clicks + clicks
            )
        }

        // Emit points for every day in the window, padding zeros.
        return (0..<days).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index, to: startDay) else { return nil }
            let agg = buckets[index] ?? (0, 0.0, 0)
            return DailyTrendPoint(
                day: day,
                keyPresses: agg.keys,
                mouseClicks: agg.clicks,
                mouseDistanceMillimeters: agg.distance
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
}

// MARK: - Value types

public struct TodaySummary: Sendable, Equatable {
    public let totalKeyPresses: Int
    public let totalMouseClicks: Int
    public let totalMouseMovesRaw: Int
    public let totalMouseDistanceMillimeters: Double
    public let totalActiveSeconds: Int
    public let topApps: [AppUsageRow]

    public init(
        totalKeyPresses: Int,
        totalMouseClicks: Int,
        totalMouseMovesRaw: Int,
        totalMouseDistanceMillimeters: Double,
        totalActiveSeconds: Int,
        topApps: [AppUsageRow]
    ) {
        self.totalKeyPresses = totalKeyPresses
        self.totalMouseClicks = totalMouseClicks
        self.totalMouseMovesRaw = totalMouseMovesRaw
        self.totalMouseDistanceMillimeters = totalMouseDistanceMillimeters
        self.totalActiveSeconds = totalActiveSeconds
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

    public var id: TimeInterval { day.timeIntervalSince1970 }

    public init(
        day: Date,
        keyPresses: Int,
        mouseClicks: Int,
        mouseDistanceMillimeters: Double
    ) {
        self.day = day
        self.keyPresses = keyPresses
        self.mouseClicks = mouseClicks
        self.mouseDistanceMillimeters = mouseDistanceMillimeters
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

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
            // Mouse: prefer min_mouse for closed minutes; add the open
            // bucket from sec_mouse for the partial latest minute.
            let mouseDistanceMin = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(distance_mm), 0.0) FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseClicksMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(click_events), 0) FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseDistanceSec = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(distance_mm), 0.0) FROM sec_mouse
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0
            let mouseClicksSec = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(click_events), 0) FROM sec_mouse
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0

            // Keys: same closed/open layering.
            let keyPressesMin = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(press_count), 0) FROM min_key
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startSec, endSec]) ?? 0
            let keyPressesSec = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(press_count), 0) FROM sec_key
                WHERE ts_second >= ? AND ts_second < ?
                """, arguments: [startSec, endSec]) ?? 0

            // L0 raw rows that haven't been rolled yet.
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
                totalKeyPresses: keyPressesMin + keyPressesSec + rawKeys,
                totalMouseClicks: mouseClicksMin + mouseClicksSec + rawClicks,
                totalMouseMovesRaw: rawMoves,
                totalMouseDistanceMillimeters: mouseDistanceMin + mouseDistanceSec,
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

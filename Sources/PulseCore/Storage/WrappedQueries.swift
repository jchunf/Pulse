import Foundation
import GRDB

/// F-24 — "Year wrapped" aggregate. Spotify-style year-to-date
/// summary built from the data Pulse already records, with no new
/// collection. Queried on demand (open the wrapped window) rather
/// than per refresh, so it can afford a few extra round-trips
/// against `hour_summary` that the Dashboard's per-tick loop
/// avoids.
///
/// Year window: the caller passes `yearStart` (typically Jan 1
/// 00:00 local) and the snapshot's "year" runs from there to
/// `capUntil` (typically `Date()`). Stops at `capUntil` so the
/// hero "you've been here N days" doesn't promise full-year data
/// in April.
public struct YearWrappedSnapshot: Sendable, Equatable {

    /// Inclusive lower bound of the window — typically the start
    /// of the calendar year in the user's local time.
    public let yearStart: Date

    /// Exclusive upper bound — typically `Date()`.
    public let capturedAt: Date

    /// Distinct calendar days with at least one rolled-up hour.
    /// Counts "days you used Pulse" — a fresh install in April
    /// reads a month or two, not a year.
    public let daysActive: Int

    /// Earliest `hour_summary` timestamp within the year window;
    /// `nil` if no data has rolled up yet for the year.
    public let firstActiveAt: Date?

    /// Sum of every `key_press_total` row in `hour_summary` for
    /// the year. Permanent retention by design — see
    /// `docs/03-data-collection.md` §二.
    public let totalKeyPresses: Int

    /// Sum of every `mouse_click_total` row in `hour_summary` for
    /// the year.
    public let totalMouseClicks: Int

    /// Sum of every `mouse_distance_mm` row in `hour_summary` for
    /// the year. Quoted to the user as kilometres + a landmark
    /// comparison (LandmarkLibrary).
    public let totalMouseDistanceMillimeters: Double

    /// Sum of every `scroll_ticks` row in `hour_summary` for the
    /// year.
    public let totalScrollTicks: Int

    /// Top 5 apps by time used over the year, computed via the
    /// existing `appUsageRanking` query against the year window.
    public let topApps: [AppUsageRow]

    /// Year's single longest uninterrupted run in one app while
    /// not idle. Computed by iterating `longestFocusSegment`
    /// per day inside the year window — N ≈ 365 day-scoped reads,
    /// each over already-rolled `min_idle` rows, which is fine
    /// for a one-shot wrapped invocation.
    public let longestFocus: FocusSegment?

    /// The day with the most (`key_press_total + mouse_click_total`)
    /// in `hour_summary`. `nil` when the year has zero activity.
    public let busiestDay: BusiestDay?

    /// Chronotype derived over a 90-day rolling window ending at
    /// `capturedAt`. `nil` when there's not enough data to pick a
    /// stable peak hour.
    public let chronotype: Chronotype?

    /// Hour of day (0-23 local) with the highest total
    /// `key_press_total + mouse_click_total` summed across the
    /// year. Different from chronotype's circular-mean: this
    /// answers "literally which hour had the most clicks/keys",
    /// which is more legible in a wrapped narrative.
    public let mostActiveHourOfDay: Int?

    /// Number of distinct hours-of-day (0-24) the user was
    /// recorded as active in. A "23 of 24 hours" answer is
    /// surprisingly common and reads as a fun fact.
    public let distinctActiveHoursOfDay: Int

    /// Sum of every `foreground_app` row in `system_events` for
    /// the year — i.e. how often the user changed which app was
    /// frontmost.
    public let totalAppSwitches: Int

    public init(
        yearStart: Date,
        capturedAt: Date,
        daysActive: Int,
        firstActiveAt: Date?,
        totalKeyPresses: Int,
        totalMouseClicks: Int,
        totalMouseDistanceMillimeters: Double,
        totalScrollTicks: Int,
        topApps: [AppUsageRow],
        longestFocus: FocusSegment?,
        busiestDay: BusiestDay?,
        chronotype: Chronotype?,
        mostActiveHourOfDay: Int?,
        distinctActiveHoursOfDay: Int,
        totalAppSwitches: Int
    ) {
        self.yearStart = yearStart
        self.capturedAt = capturedAt
        self.daysActive = daysActive
        self.firstActiveAt = firstActiveAt
        self.totalKeyPresses = totalKeyPresses
        self.totalMouseClicks = totalMouseClicks
        self.totalMouseDistanceMillimeters = totalMouseDistanceMillimeters
        self.totalScrollTicks = totalScrollTicks
        self.topApps = topApps
        self.longestFocus = longestFocus
        self.busiestDay = busiestDay
        self.chronotype = chronotype
        self.mostActiveHourOfDay = mostActiveHourOfDay
        self.distinctActiveHoursOfDay = distinctActiveHoursOfDay
        self.totalAppSwitches = totalAppSwitches
    }
}

/// Day with the most activity in the year.
public struct BusiestDay: Sendable, Equatable {
    /// Local-day boundary (00:00 in the user's local time on the
    /// busiest date).
    public let day: Date
    /// Sum of `key_press_total + mouse_click_total` for that day.
    public let totalEvents: Int

    public init(day: Date, totalEvents: Int) {
        self.day = day
        self.totalEvents = totalEvents
    }
}

public extension EventStore {

    /// Build a `YearWrappedSnapshot`. Walks `hour_summary` and the
    /// existing per-day queries — no new collection, all sources
    /// already disclosed in `docs/03-data-collection.md`.
    func yearWrappedSnapshot(
        yearStart: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> YearWrappedSnapshot {
        let yearStartSec = Int64(yearStart.timeIntervalSince1970)
        let capUntilSec = Int64(capUntil.timeIntervalSince1970)
        let yearStartMs = Int64(yearStart.timeIntervalSince1970 * 1_000)
        let capUntilMs = Int64(capUntil.timeIntervalSince1970 * 1_000)
        let localOffsetSec = Int64(calendar.timeZone.secondsFromGMT(for: yearStart))

        // Sum totals straight from `hour_summary` — one PK-range scan.
        let totals = try database.queue.read { db -> (keys: Int, clicks: Int, distance: Double, scrolls: Int) in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(key_press_total), 0)   AS keys,
                    COALESCE(SUM(mouse_click_total), 0) AS clicks,
                    COALESCE(SUM(mouse_distance_mm), 0.0) AS distance,
                    COALESCE(SUM(scroll_ticks), 0)      AS scrolls
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [yearStartSec, capUntilSec])
            return (
                keys: row?["keys"] ?? 0,
                clicks: row?["clicks"] ?? 0,
                distance: row?["distance"] ?? 0,
                scrolls: row?["scrolls"] ?? 0
            )
        }

        // Distinct days + first-active timestamp.
        let dayStats = try database.queue.read { db -> (days: Int, firstAt: Date?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT (ts_hour + ?) / 86400) AS days,
                       MIN(ts_hour) AS first_ts
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                """, arguments: [localOffsetSec, yearStartSec, capUntilSec])
            let days: Int = row?["days"] ?? 0
            let firstTs: Int64? = row?["first_ts"]
            return (
                days: days,
                firstAt: firstTs.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }

        // Top 5 apps over the year.
        let topApps = try appUsageRanking(
            start: yearStart,
            end: capUntil,
            capUntil: capUntil,
            limit: 5
        )

        // Busiest single day (local).
        let busiest = try database.queue.read { db -> BusiestDay? in
            let row = try Row.fetchOne(db, sql: """
                SELECT (ts_hour + ?) / 86400 AS day_idx,
                       COALESCE(SUM(key_press_total + mouse_click_total), 0) AS total
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                GROUP BY day_idx
                ORDER BY total DESC
                LIMIT 1
                """, arguments: [localOffsetSec, yearStartSec, capUntilSec])
            guard let row,
                  let dayIdx = row["day_idx"] as Int64?,
                  let total = row["total"] as Int?,
                  total > 0
            else {
                return nil
            }
            // Reconstruct the local-day boundary in epoch seconds:
            // dayIdx * 86400 - localOffsetSec gives the UTC second
            // for local 00:00 on that day.
            let dayEpoch = dayIdx * 86_400 - localOffsetSec
            return BusiestDay(
                day: Date(timeIntervalSince1970: TimeInterval(dayEpoch)),
                totalEvents: total
            )
        }

        // Hour-of-day distribution: which hour had the most activity?
        let hourStats = try database.queue.read { db -> (peakHour: Int?, distinct: Int) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ((ts_hour + ?) / 3600) % 24 AS hod,
                       COALESCE(SUM(key_press_total + mouse_click_total), 0) AS total
                FROM hour_summary
                WHERE ts_hour >= ? AND ts_hour < ?
                GROUP BY hod
                """, arguments: [localOffsetSec, yearStartSec, capUntilSec])
            var distinct = 0
            var peakHour: Int? = nil
            var peakTotal: Int = -1
            for row in rows {
                let h: Int = row["hod"] ?? 0
                let t: Int = row["total"] ?? 0
                if t > 0 { distinct += 1 }
                if t > peakTotal { peakTotal = t; peakHour = Int(h) }
            }
            return (peakHour: peakHour, distinct: distinct)
        }

        // App switches sourced from `system_events` directly so the
        // count covers both rolled-up and unrolled portions.
        let totalAppSwitches = try database.queue.read { db -> Int in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                """, arguments: [yearStartMs, capUntilMs]) ?? 0
        }

        // Longest focus segment across the year — iterate per day,
        // take max. Each call is a small `min_idle` + `system_events`
        // scoped read, so 365 of them is a few hundred ms at most.
        var longestFocus: FocusSegment? = nil
        var dayCursor = calendar.startOfDay(for: yearStart)
        let endBoundary = min(capUntil, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: capUntil)) ?? capUntil)
        while dayCursor < endBoundary {
            if let segment = try? longestFocusSegment(on: dayCursor, calendar: calendar, now: capUntil) {
                if (longestFocus?.durationSeconds ?? -1) < segment.durationSeconds {
                    longestFocus = segment
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) else {
                break
            }
            dayCursor = next
        }

        // Chronotype over a 90-day rolling window ending at the cap.
        // The full-year version of chronotype isn't more
        // informative — the circular mean stabilises in 14 days
        // and changes slowly afterwards.
        let chrono = try? chronotype(endingAt: capUntil, days: 90)

        return YearWrappedSnapshot(
            yearStart: yearStart,
            capturedAt: capUntil,
            daysActive: dayStats.days,
            firstActiveAt: dayStats.firstAt,
            totalKeyPresses: totals.keys,
            totalMouseClicks: totals.clicks,
            totalMouseDistanceMillimeters: totals.distance,
            totalScrollTicks: totals.scrolls,
            topApps: topApps,
            longestFocus: longestFocus,
            busiestDay: busiest,
            chronotype: chrono,
            mostActiveHourOfDay: hourStats.peakHour,
            distinctActiveHoursOfDay: hourStats.distinct,
            totalAppSwitches: totalAppSwitches
        )
    }
}

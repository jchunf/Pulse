import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("AppUsageQueries — read-side aggregation")
struct AppUsageQueriesTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func millis(_ instant: Date) -> Int64 {
        Int64(instant.timeIntervalSince1970 * 1_000)
    }

    /// Insert a foreground_app switch row directly so tests don't need the
    /// runtime stack.
    private func insertSwitch(into db: PulseDatabase, ts: Date, bundle: String) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'foreground_app', ?)",
                arguments: [Int64(ts.timeIntervalSince1970 * 1_000), bundle]
            )
        }
    }

    private func insertMinMouse(into db: PulseDatabase, minute: Date, distanceMm: Double, clicks: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO min_mouse (ts_minute, distance_mm, click_events)
                VALUES (?, ?, ?)
                """,
                arguments: [Int64(minute.timeIntervalSince1970), distanceMm, clicks]
            )
        }
    }

    private func insertMinKey(into db: PulseDatabase, minute: Date, presses: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_key (ts_minute, press_count) VALUES (?, ?)",
                arguments: [Int64(minute.timeIntervalSince1970), presses]
            )
        }
    }

    private func insertHourSummary(
        into db: PulseDatabase,
        hourStart: Date,
        keys: Int,
        clicks: Int,
        distanceMm: Double = 0.0,
        idleSeconds: Int = 0,
        scrollTicks: Int = 0
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [Int64(hourStart.timeIntervalSince1970), keys, distanceMm, clicks, idleSeconds, scrollTicks]
            )
        }
    }

    private func insertMinIdle(into db: PulseDatabase, minute: Date, seconds: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_idle (ts_minute, idle_seconds) VALUES (?, ?)",
                arguments: [Int64(minute.timeIntervalSince1970), seconds]
            )
        }
    }

    private func insertSecKey(into db: PulseDatabase, second: Date, presses: Int) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO sec_key (ts_second, press_count) VALUES (?, ?)",
                arguments: [Int64(second.timeIntervalSince1970), presses]
            )
        }
    }

    private func insertSecMouse(
        into db: PulseDatabase,
        second: Date,
        clicks: Int,
        distanceMm: Double
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO sec_mouse (ts_second, move_events, click_events, scroll_ticks, distance_mm) VALUES (?, 0, ?, 0, ?)",
                arguments: [Int64(second.timeIntervalSince1970), clicks, distanceMm]
            )
        }
    }

    private func insertRawKeyEvent(into db: PulseDatabase, at instant: Date) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_key_events (ts, key_code) VALUES (?, NULL)",
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000)]
            )
        }
    }

    private func insertRawMouseClick(into db: PulseDatabase, at instant: Date) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button) VALUES (?, 1, 0.5, 0.5, 'left')",
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000)]
            )
        }
    }

    private func setAppWatermark(into db: PulseDatabase, at instant: Date) throws {
        try db.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO rollup_watermarks (job, last_processed_ms)
                VALUES ('foreground_app_to_min', ?)
                ON CONFLICT(job) DO UPDATE SET last_processed_ms = excluded.last_processed_ms
                """,
                arguments: [Int64(instant.timeIntervalSince1970 * 1_000)]
            )
        }
    }

    private func insertMinApp(
        into db: PulseDatabase,
        minute: Date,
        bundle: String,
        seconds: Int64
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO min_app (ts_minute, bundle_id, seconds_used) VALUES (?, ?, ?)",
                arguments: [Int64(minute.timeIntervalSince1970), bundle, seconds]
            )
        }
    }

    private func insertHourApp(
        into db: PulseDatabase,
        hour: Date,
        bundle: String,
        seconds: Int64
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO hour_app (ts_hour, bundle_id, seconds_used) VALUES (?, ?, ?)",
                arguments: [Int64(hour.timeIntervalSince1970), bundle, seconds]
            )
        }
    }

    @Test("appUsageRanking computes intervals between switches")
    func basicRanking() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary epoch
        try insertSwitch(into: db, ts: day, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: day.addingTimeInterval(60), bundle: "com.apple.dt.Xcode")
        try insertSwitch(into: db, ts: day.addingTimeInterval(60 + 120), bundle: "com.apple.Safari")

        let cap = day.addingTimeInterval(60 + 120 + 30) // last interval = 30s
        let rows = try store.appUsageRanking(
            start: day,
            end: day.addingTimeInterval(3600),
            capUntil: cap,
            limit: 10
        )

        let bundles = rows.map(\.bundleId)
        #expect(bundles.contains("com.apple.Safari"))
        #expect(bundles.contains("com.apple.dt.Xcode"))
        let safariSeconds = rows.first { $0.bundleId == "com.apple.Safari" }?.secondsUsed
        let xcodeSeconds = rows.first { $0.bundleId == "com.apple.dt.Xcode" }?.secondsUsed
        // Safari: 60s + 30s = 90s. Xcode: 120s.
        #expect(safariSeconds == 90)
        #expect(xcodeSeconds == 120)
        // Sorted descending by seconds.
        #expect(rows.first?.bundleId == "com.apple.dt.Xcode")
    }

    @Test("ranking carries app from before the queried range")
    func priorAppCounts() async throws {
        let (store, db) = try makeStore()
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        // Switch happened yesterday — the app is still active when today
        // starts.
        try insertSwitch(into: db, ts: dayStart.addingTimeInterval(-3600), bundle: "com.apple.Mail")
        // No switches today; cap at 600s into the day.
        let cap = dayStart.addingTimeInterval(600)
        let rows = try store.appUsageRanking(
            start: dayStart,
            end: dayStart.addingTimeInterval(86_400),
            capUntil: cap,
            limit: 10
        )
        #expect(rows.count == 1)
        #expect(rows.first?.bundleId == "com.apple.Mail")
        #expect(rows.first?.secondsUsed == 600)
    }

    @Test("ranking respects the limit")
    func limitRespected() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<5 {
            try insertSwitch(
                into: db,
                ts: day.addingTimeInterval(Double(offset) * 60),
                bundle: "com.bundle.\(offset)"
            )
        }
        let cap = day.addingTimeInterval(5 * 60 + 60)
        let rows = try store.appUsageRanking(
            start: day,
            end: day.addingTimeInterval(3600),
            capUntil: cap,
            limit: 3
        )
        #expect(rows.count == 3)
    }

    @Test("todaySummary sums mouse / key / app metrics")
    func summarySumsMetrics() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // 3 minutes of mouse activity.
        try insertMinMouse(into: db, minute: day, distanceMm: 100, clicks: 5)
        try insertMinMouse(into: db, minute: day.addingTimeInterval(60), distanceMm: 200, clicks: 7)
        try insertMinMouse(into: db, minute: day.addingTimeInterval(120), distanceMm: 50, clicks: 3)
        // Key activity in the same minutes.
        try insertMinKey(into: db, minute: day, presses: 40)
        try insertMinKey(into: db, minute: day.addingTimeInterval(60), presses: 60)
        // One app switch giving 90 seconds of Safari usage.
        try insertSwitch(into: db, ts: day, bundle: "com.apple.Safari")
        let cap = day.addingTimeInterval(90)

        let summary = try store.todaySummary(
            start: day,
            end: day.addingTimeInterval(86_400),
            capUntil: cap
        )

        #expect(summary.totalKeyPresses == 100)
        #expect(summary.totalMouseClicks == 15)
        #expect(summary.totalMouseDistanceMillimeters == 350.0)
        #expect(summary.totalActiveSeconds == 90)
        #expect(summary.topApps.first?.bundleId == "com.apple.Safari")
    }

    @Test("dailyTrend returns `days` points with zero-padding and oldest-first order")
    func trendPadsAndOrders() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let endingAt = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 14))!
        let endDay = calendar.startOfDay(for: endingAt)

        // Activity only on today (10:00) and 3 days ago (22:00).
        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(10 * 3600), keys: 50, clicks: 20)
        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(-3 * 86_400 + 22 * 3600), keys: 5, clicks: 5)

        let points = try store.dailyTrend(endingAt: endingAt, days: 7, calendar: calendar)
        #expect(points.count == 7)

        // Oldest → newest: index 0 = 6 days ago, index 6 = today.
        for i in 0..<7 {
            let expectedDay = calendar.date(byAdding: .day, value: i - 6, to: endDay)!
            #expect(calendar.isDate(points[i].day, inSameDayAs: expectedDay))
        }
        // Total events per day.
        #expect(points[0].totalEvents == 0)   // 6 days ago
        #expect(points[3].totalEvents == 10)  // 3 days ago (22:00 = 5+5)
        #expect(points[6].totalEvents == 70)  // today (10:00 = 50+20)
    }

    @Test("dailyTrend aggregates multiple hours into one day bucket")
    func trendSumsHoursPerDay() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let endingAt = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 14))!
        let endDay = calendar.startOfDay(for: endingAt)

        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(9 * 3600), keys: 10, clicks: 5)
        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(10 * 3600), keys: 20, clicks: 15)
        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(11 * 3600), keys: 30, clicks: 0)

        let points = try store.dailyTrend(endingAt: endingAt, days: 3, calendar: calendar)
        let today = points.last!
        #expect(today.keyPresses == 60)
        #expect(today.mouseClicks == 20)
        #expect(today.totalEvents == 80)
    }

    @Test("dailyTrend carries scroll_ticks and idle_seconds per day")
    func trendCarriesScrollAndIdle() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let endingAt = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 1, day: 10, hour: 14
        ))!
        let endDay = calendar.startOfDay(for: endingAt)

        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(9 * 3600),
                              keys: 0, clicks: 0,
                              idleSeconds: 120, scrollTicks: 25)
        try insertHourSummary(into: db, hourStart: endDay.addingTimeInterval(10 * 3600),
                              keys: 0, clicks: 0,
                              idleSeconds: 30, scrollTicks: 70)

        let points = try store.dailyTrend(endingAt: endingAt, days: 3, calendar: calendar)
        let today = points.last!
        #expect(today.idleSeconds == 150)
        #expect(today.scrollTicks == 95)
    }

    @Test("hourlyHeatmap maps ts_hour rows to dayOffset + hour cells")
    func heatmapMapsRows() async throws {
        let (store, db) = try makeStore()
        // Use a fixed UTC calendar so tests are deterministic across runners.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // endingAt: 2026-01-10 14:30 UTC.
        let comps = DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 1, day: 10, hour: 14, minute: 30
        )
        let endingAt = calendar.date(from: comps)!
        let endDay = calendar.startOfDay(for: endingAt)

        // Insert hour_summary rows: 3 hours total.
        // today 10:00 (activity 7), today 11:00 (activity 13), yesterday 22:00 (activity 5)
        let today10 = endDay.addingTimeInterval(10 * 3600)
        let today11 = endDay.addingTimeInterval(11 * 3600)
        let yesterday22 = endDay.addingTimeInterval(-2 * 3600)
        for (date, keys, clicks) in [
            (today10, 4, 3),
            (today11, 10, 3),
            (yesterday22, 2, 3)
        ] {
            try insertHourSummary(into: db, hourStart: date, keys: keys, clicks: clicks)
        }

        let cells = try store.hourlyHeatmap(endingAt: endingAt, days: 7, calendar: calendar)

        // Build a lookup so ordering doesn't matter.
        let lookup: [String: Int] = Dictionary(
            uniqueKeysWithValues: cells.map { ("\($0.dayOffset)-\($0.hour)", $0.activityCount) }
        )
        #expect(lookup["0-10"] == 7)   // today 10:00
        #expect(lookup["0-11"] == 13)  // today 11:00
        #expect(lookup["1-22"] == 5)   // yesterday 22:00
        #expect(cells.count == 3)
    }

    @Test("hourlyHeatmap excludes zero-activity rows")
    func heatmapExcludesZero() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let endingAt = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 23))!
        let hourStart = calendar.startOfDay(for: endingAt).addingTimeInterval(3 * 3600)

        try insertHourSummary(into: db, hourStart: hourStart, keys: 0, clicks: 0)
        let cells = try store.hourlyHeatmap(endingAt: endingAt, days: 2, calendar: calendar)
        #expect(cells.isEmpty)
    }

    @Test("hourlyHeatmap ignores data outside the requested window")
    func heatmapBoundedByDays() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let endingAt = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 14))!
        let endDay = calendar.startOfDay(for: endingAt)

        // 10 days ago — outside any reasonable window.
        let outside = endDay.addingTimeInterval(-10 * 86_400 + 12 * 3600)
        try insertHourSummary(into: db, hourStart: outside, keys: 100, clicks: 50)
        let cells = try store.hourlyHeatmap(endingAt: endingAt, days: 7, calendar: calendar)
        #expect(cells.isEmpty)
    }

    @Test("todaySummary layers hour_summary + min_* + sec_* + raw for one metric")
    func summaryLayersAcrossRollupStates() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 0
        ))!
        let now = day.addingTimeInterval(9 * 3_600 + 30 * 60 + 15) // 09:30:15

        // Hours 07:00 and 08:00 are fully rolled → in hour_summary.
        try insertHourSummary(into: db, hourStart: day.addingTimeInterval(7 * 3_600), keys: 200, clicks: 30, distanceMm: 50_000)
        try insertHourSummary(into: db, hourStart: day.addingTimeInterval(8 * 3_600), keys: 150, clicks: 20, distanceMm: 40_000)

        // Minute 09:00 rolled to min_* but hour 9 hasn't promoted yet.
        try insertMinKey(into: db, minute: day.addingTimeInterval(9 * 3_600), presses: 20)
        try insertMinMouse(into: db, minute: day.addingTimeInterval(9 * 3_600), distanceMm: 1_500, clicks: 3)

        // Seconds 09:30:00..09:30:09 rolled to sec_* but not min_* yet.
        let secondsStart = day.addingTimeInterval(9 * 3_600 + 30 * 60)
        for offset in 0..<10 {
            let second = secondsStart.addingTimeInterval(Double(offset))
            try insertSecKey(into: db, second: second, presses: 5)
            try insertSecMouse(into: db, second: second, clicks: 1, distanceMm: 100)
        }

        // Raw rows that haven't been promoted to sec yet (next 5 seconds).
        let rawStart = secondsStart.addingTimeInterval(10)
        for offset in 0..<5 {
            let instant = rawStart.addingTimeInterval(Double(offset))
            try insertRawKeyEvent(into: db, at: instant)
            try insertRawMouseClick(into: db, at: instant)
        }

        let summary = try store.todaySummary(
            start: day,
            end: day.addingTimeInterval(86_400),
            capUntil: now
        )

        // Keys: 200 + 150 (hour) + 20 (min) + 50 (sec: 5×10) + 5 (raw) = 425.
        let expectedKeys = 425
        #expect(summary.totalKeyPresses == expectedKeys)
        // Clicks: 30 + 20 (hour) + 3 (min) + 10 (sec) + 5 (raw) = 68.
        let expectedClicks = 68
        #expect(summary.totalMouseClicks == expectedClicks)
        // Distance: 50_000 + 40_000 (hour) + 1_500 (min) + 1_000 (sec: 10×100) = 92_500 mm.
        let expectedDistance: Double = 92_500
        #expect(summary.totalMouseDistanceMillimeters == expectedDistance)
    }

    // MARK: - Layered app-usage ranking (A7)

    @Test("appUsageRanking reads min_app rows for the rolled portion of the range")
    func rankingReadsMinApp() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        try insertMinApp(into: db, minute: day, bundle: "com.apple.Safari", seconds: 40)
        try insertMinApp(into: db, minute: day.addingTimeInterval(60), bundle: "com.apple.Safari", seconds: 60)
        try insertMinApp(into: db, minute: day.addingTimeInterval(120), bundle: "com.apple.dt.Xcode", seconds: 50)
        let watermark = day.addingTimeInterval(600)
        try setAppWatermark(into: db, at: watermark)

        let rows = try store.appUsageRanking(
            start: day,
            end: day.addingTimeInterval(3_600),
            capUntil: watermark,
            limit: 10
        )
        #expect(rows.count == 2)
        #expect(rows.first?.bundleId == "com.apple.Safari")
        #expect(rows.first?.secondsUsed == 100)
        #expect(rows.last?.bundleId == "com.apple.dt.Xcode")
        #expect(rows.last?.secondsUsed == 50)
    }

    @Test("appUsageRanking reads hour_app rows for fully-rolled hours")
    func rankingReadsHourApp() async throws {
        let (store, db) = try makeStore()
        let hour = Date(timeIntervalSince1970: 1_700_000_000)
        try insertHourApp(into: db, hour: hour, bundle: "com.apple.Safari", seconds: 1_800)
        try insertHourApp(into: db, hour: hour, bundle: "com.apple.dt.Xcode", seconds: 1_200)
        let watermark = hour.addingTimeInterval(3_600)
        try setAppWatermark(into: db, at: watermark)

        let rows = try store.appUsageRanking(
            start: hour,
            end: hour.addingTimeInterval(7_200),
            capUntil: watermark,
            limit: 10
        )
        #expect(rows.map(\.bundleId) == ["com.apple.Safari", "com.apple.dt.Xcode"])
        #expect(rows.first?.secondsUsed == 1_800)
        #expect(rows.last?.secondsUsed == 1_200)
    }

    @Test("appUsageRanking ignores system_events that sit below the watermark")
    func rankingAvoidsDoubleCountBelowWatermark() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // Raw switches that, if LEAD'd, would give Safari 100 seconds.
        try insertSwitch(into: db, ts: day, bundle: "com.apple.Safari")
        try insertSwitch(into: db, ts: day.addingTimeInterval(100), bundle: "com.apple.dt.Xcode")
        // And the same data rolled into min_app, at 40 seconds of Safari.
        try insertMinApp(into: db, minute: day, bundle: "com.apple.Safari", seconds: 40)
        // Watermark claims the whole range is rolled.
        let watermark = day.addingTimeInterval(200)
        try setAppWatermark(into: db, at: watermark)

        let rows = try store.appUsageRanking(
            start: day,
            end: day.addingTimeInterval(3_600),
            capUntil: watermark,
            limit: 10
        )
        // Only the rolled min_app value should count; the raw LEAD is skipped.
        #expect(rows.count == 1)
        #expect(rows.first?.bundleId == "com.apple.Safari")
        #expect(rows.first?.secondsUsed == 40)
    }

    @Test("appUsageRanking unions rolled + post-watermark raw contributions")
    func rankingLayersRolledAndRaw() async throws {
        let (store, db) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // Rolled: 600s of Safari in hour_app.
        let priorHour = day.addingTimeInterval(-3_600)
        try insertHourApp(into: db, hour: priorHour, bundle: "com.apple.Safari", seconds: 600)
        // Rolled: 30s of Xcode in min_app at `day`.
        try insertMinApp(into: db, minute: day, bundle: "com.apple.dt.Xcode", seconds: 30)
        // Watermark sits 60 seconds after `day`.
        let watermark = day.addingTimeInterval(60)
        try setAppWatermark(into: db, at: watermark)
        // Raw post-watermark: Safari activates at the watermark and runs 30 seconds.
        try insertSwitch(into: db, ts: watermark, bundle: "com.apple.Safari")
        let cap = watermark.addingTimeInterval(30)

        let rows = try store.appUsageRanking(
            start: priorHour,
            end: day.addingTimeInterval(3_600),
            capUntil: cap,
            limit: 10
        )
        let safariSeconds = rows.first(where: { $0.bundleId == "com.apple.Safari" })?.secondsUsed
        let xcodeSeconds = rows.first(where: { $0.bundleId == "com.apple.dt.Xcode" })?.secondsUsed
        #expect(safariSeconds == 630)  // 600 from hour_app + 30 raw
        #expect(xcodeSeconds == 30)    // from min_app only
    }

    @Test("todaySummary sums idle seconds across hour_summary + min_idle")
    func summaryLayersIdleSeconds() async throws {
        let (store, db) = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 1, day: 10, hour: 0
        ))!
        let now = day.addingTimeInterval(9 * 3_600 + 30 * 60)

        // 2 completed hours of idle in hour_summary (480 s each) — rolled
        // already — plus one minute of idle in min_idle (37 s) still
        // awaiting promotion.
        try insertHourSummary(into: db, hourStart: day.addingTimeInterval(7 * 3_600), keys: 0, clicks: 0, idleSeconds: 480)
        try insertHourSummary(into: db, hourStart: day.addingTimeInterval(8 * 3_600), keys: 0, clicks: 0, idleSeconds: 480)
        try insertMinIdle(into: db, minute: day.addingTimeInterval(9 * 3_600), seconds: 37)

        let summary = try store.todaySummary(
            start: day,
            end: day.addingTimeInterval(86_400),
            capUntil: now
        )
        #expect(summary.totalIdleSeconds == 480 + 480 + 37)
    }

    @Test("queries handle an empty database")
    func emptyDb() async throws {
        let (store, _) = try makeStore()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = try store.todaySummary(
            start: day,
            end: day.addingTimeInterval(86_400),
            capUntil: day.addingTimeInterval(3600)
        )
        #expect(summary.totalKeyPresses == 0)
        #expect(summary.totalMouseClicks == 0)
        #expect(summary.totalMouseDistanceMillimeters == 0.0)
        #expect(summary.totalActiveSeconds == 0)
        #expect(summary.topApps.isEmpty)
    }
}

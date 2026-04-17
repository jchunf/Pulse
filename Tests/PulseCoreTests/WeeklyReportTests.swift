import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("WeeklyReport — data assembly + HTML renderer")
struct WeeklyReportTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test("weeklyReport assembles 7 days of trend points ordered oldest → newest")
    func weeklyReportShape() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let endingAt = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 4, day: 17, hour: 12
        ))!
        let endDay = calendar.startOfDay(for: endingAt)

        // Seed two days of activity via hour_summary + min_key / min_mouse (trend reads hour_summary).
        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 100, 1234.5, 20, 300, 5)
                """, arguments: [Int64(endDay.addingTimeInterval(9 * 3_600).timeIntervalSince1970)])
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 50, 500, 10, 60, 0)
                """, arguments: [Int64(endDay.addingTimeInterval(-1 * 86_400 + 10 * 3_600).timeIntervalSince1970)])
        }

        let report = try store.weeklyReport(
            endingAt: endingAt,
            days: 7,
            calendar: calendar
        )
        #expect(report.days.count == 7)
        #expect(report.days.first?.day == calendar.date(byAdding: .day, value: -6, to: endDay))
        #expect(report.days.last?.day == endDay)
        #expect(report.totalKeystrokes == 150)
        #expect(report.totalClicks == 30)
        #expect(report.totalScrollTicks == 5)
        #expect(report.totalDistanceMillimeters == 1734.5)
        #expect(report.totalIdleSeconds == 360)
    }

    @Test("HTML renderer emits all required sections and escapes input")
    func htmlRendererRoundtrip() throws {
        let (store, db) = try makeStore()
        let calendar = utcCalendar()
        let endingAt = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 4, day: 17, hour: 23
        ))!
        let endDay = calendar.startOfDay(for: endingAt)

        try db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO hour_summary (ts_hour, key_press_total, mouse_distance_mm, mouse_click_total, idle_seconds, scroll_ticks)
                VALUES (?, 10, 500, 2, 0, 1)
                """, arguments: [Int64(endDay.addingTimeInterval(14 * 3_600).timeIntervalSince1970)])
            // A foreground_app payload with HTML-sensitive characters to exercise escape().
            try db.execute(sql: """
                INSERT INTO system_events (ts, category, payload)
                VALUES (?, 'foreground_app', 'com.<script>Example')
                """, arguments: [Int64(endDay.addingTimeInterval(10 * 3_600).timeIntervalSince1970 * 1_000)])
        }

        let report = try store.weeklyReport(
            endingAt: endingAt,
            days: 7,
            calendar: calendar
        )
        let renderer = WeeklyReportHTMLRenderer()
        let strings = WeeklyReportHTMLRenderer.Strings(
            title: "Weekly", subtitle: "1–7",
            distanceLabel: "Distance",
            keystrokesLabel: "Keystrokes",
            clicksLabel: "Clicks",
            scrollsLabel: "Scrolls",
            idleLabel: "Idle",
            topAppsHeading: "Apps",
            dailyBreakdownHeading: "Days",
            dayHeader: "Day", appHeader: "App", secondsHeader: "Seconds",
            landmarkSentence: "roughly 1× a kilometer",
            generatedFooter: "Generated now"
        )
        let formatters = WeeklyReportHTMLRenderer.Formatters(
            distance: { "\(Int($0)) mm" },
            integer: { "\($0)" },
            duration: { "\($0) s" },
            date: { _ in "d" },
            appDisplayName: { $0 }
        )
        let html = renderer.render(report: report, strings: strings, formatters: formatters)

        // Document skeleton
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("<title>Weekly</title>"))
        // Localised strings flow through.
        #expect(html.contains("Keystrokes"))
        #expect(html.contains("Apps"))
        #expect(html.contains("Days"))
        #expect(html.contains("Generated now"))
        // Hero number renders from the distance formatter (500mm total).
        #expect(html.contains("500 mm"))
        // HTML-sensitive characters in bundle id are escaped.
        #expect(html.contains("com.&lt;script&gt;Example"))
        #expect(!html.contains("<script>Example"))
    }
}

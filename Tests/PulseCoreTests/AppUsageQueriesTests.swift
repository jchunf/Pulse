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

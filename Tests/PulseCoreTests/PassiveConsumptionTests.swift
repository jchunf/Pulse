import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("PassiveConsumption — screen-on idle attributed to foreground apps (F-22)")
struct PassiveConsumptionTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    /// Write a single row into `system_events`. Timestamps are epoch ms
    /// — same convention the runtime uses.
    private func insertEvent(
        into db: PulseDatabase,
        at: Date,
        category: String,
        payload: String? = nil
    ) throws {
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, ?)",
                arguments: [Int64(at.timeIntervalSince1970 * 1_000), category, payload]
            )
        }
    }

    private let dayStart = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("empty DB returns empty consumption")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: dayStart.addingTimeInterval(3_600),
            calendar: .gmt
        )
        #expect(result.totalSeconds == 0)
        #expect(result.topBundle == nil)
    }

    @Test("idle while an app is foregrounded counts as passive")
    func idleWithForegroundAppAttributed() throws {
        let (store, db) = try makeStore()
        // 10:00 — Safari takes foreground.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "foreground_app", payload: "com.apple.Safari")
        // 10:05 — idle kicks in.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_300),
                        category: "idle_entered")
        // 10:25 — user wakes.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(37_500),
                        category: "idle_exited")

        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: dayStart.addingTimeInterval(86_400),
            calendar: .gmt
        )
        #expect(result.totalSeconds == 1_200)       // 20 min
        #expect(result.topBundle?.bundleId == "com.apple.Safari")
        #expect(result.topBundle?.seconds == 1_200)
    }

    @Test("lock → unlock inside idle window is subtracted")
    func screenLockSubtracted() throws {
        let (store, db) = try makeStore()
        // 10:00 — Safari in front.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "foreground_app", payload: "com.apple.Safari")
        // 10:05 — idle.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_300),
                        category: "idle_entered")
        // 10:10 — screen locks.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_600),
                        category: "lock")
        // 10:40 — screen unlocked.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(38_400),
                        category: "unlock")
        // 10:50 — idle exits.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(39_000),
                        category: "idle_exited")

        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: dayStart.addingTimeInterval(86_400),
            calendar: .gmt
        )
        // 45 min idle total, 30 min locked → 15 min passive.
        #expect(result.totalSeconds == 900)
        #expect(result.topBundle?.bundleId == "com.apple.Safari")
    }

    @Test("system shell bundles are dropped from passive attribution")
    func systemShellBundleFiltered() throws {
        let (store, db) = try makeStore()
        // `loginwindow` takes foreground (happens when screen locks),
        // then an idle window opens and closes while it is the active
        // app. `loginwindow` is in `SystemAppFilter.excludedBundles`,
        // so the segment must not count.
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "foreground_app", payload: "com.apple.loginwindow")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_300),
                        category: "idle_entered")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(37_500),
                        category: "idle_exited")

        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: dayStart.addingTimeInterval(86_400),
            calendar: .gmt
        )
        #expect(result.totalSeconds == 0)
        #expect(result.topBundle == nil)
    }

    @Test("top bundle picks the app with the most passive seconds")
    func topBundleAggregation() throws {
        let (store, db) = try makeStore()
        // Safari passive 5 min (10:00-10:05).
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "foreground_app", payload: "com.apple.Safari")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "idle_entered")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_300),
                        category: "idle_exited")
        // VLC passive 10 min (11:00-11:10).
        try insertEvent(into: db, at: dayStart.addingTimeInterval(39_600),
                        category: "foreground_app", payload: "org.videolan.vlc")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(39_600),
                        category: "idle_entered")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(40_200),
                        category: "idle_exited")

        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: dayStart.addingTimeInterval(86_400),
            calendar: .gmt
        )
        #expect(result.totalSeconds == 900)
        #expect(result.topBundle?.bundleId == "org.videolan.vlc")
        #expect(result.topBundle?.seconds == 600)
    }

    @Test("idle open at capUntil is closed at the cap")
    func openIdleClosedAtCap() throws {
        let (store, db) = try makeStore()
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_000),
                        category: "foreground_app", payload: "com.apple.Safari")
        try insertEvent(into: db, at: dayStart.addingTimeInterval(36_300),
                        category: "idle_entered")
        // No idle_exited — user still idle as of the cap.
        let cap = dayStart.addingTimeInterval(36_900) // 10 min into idle
        let result = try store.passiveConsumption(
            on: dayStart,
            capUntil: cap,
            calendar: .gmt
        )
        #expect(result.totalSeconds == 600)
    }
}

private extension Calendar {
    static var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

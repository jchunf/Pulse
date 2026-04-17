import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("EventStore.buildPrivacyAuditSnapshot — user-facing raw ledger")
struct PrivacyAuditTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    private func insertRaws(
        into db: PulseDatabase,
        moves: [Int64] = [],
        clicks: [Int64] = [],
        keysWithoutCode: [Int64] = [],
        keysWithCode: [(ts: Int64, code: Int64)] = [],
        system: [(ts: Int64, category: String, payload: String?)] = []
    ) throws {
        try db.queue.write { db in
            for ts in moves {
                try db.execute(
                    sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, 0, 0.5, 0.5)",
                    arguments: [ts]
                )
            }
            for ts in clicks {
                try db.execute(
                    sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button, is_double) VALUES (?, 0, 0.5, 0.5, 'left', 0)",
                    arguments: [ts]
                )
            }
            for ts in keysWithoutCode {
                try db.execute(
                    sql: "INSERT INTO raw_key_events (ts, key_code) VALUES (?, NULL)",
                    arguments: [ts]
                )
            }
            for k in keysWithCode {
                try db.execute(
                    sql: "INSERT INTO raw_key_events (ts, key_code) VALUES (?, ?)",
                    arguments: [k.ts, k.code]
                )
            }
            for ev in system {
                try db.execute(
                    sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, ?)",
                    arguments: [ev.ts, ev.category, ev.payload]
                )
            }
        }
    }

    @Test("counts only rows inside the window and exposes key-code opt-in state")
    func countsInsideWindow() throws {
        let (store, db) = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let in30sMs = nowMs - 30_000
        let outMs = nowMs - 3_700_000 // just past the 1-hour window

        try insertRaws(
            into: db,
            moves: [in30sMs, in30sMs + 100, outMs],
            clicks: [in30sMs + 200],
            keysWithoutCode: [in30sMs + 300, in30sMs + 400],
            keysWithCode: [],
            system: []
        )

        let snap = try store.buildPrivacyAuditSnapshot(now: now, windowSeconds: 3600)
        #expect(snap.mouseMoveCount == 2)      // 3rd one sits outside the hour
        #expect(snap.mouseClickCount == 1)
        #expect(snap.keyPressCount == 2)
        #expect(snap.keyCodesRecorded == 0)     // default privacy-first mode
        #expect(snap.windowEnd == now)
    }

    @Test("reports a non-zero keyCodesRecorded when any row stores its key_code")
    func keyCodesVisibleWhenRecorded() throws {
        let (store, db) = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        try insertRaws(
            into: db,
            keysWithoutCode: [nowMs - 10_000],
            keysWithCode: [(ts: nowMs - 5_000, code: 12)]
        )

        let snap = try store.buildPrivacyAuditSnapshot(now: now, windowSeconds: 3600)
        #expect(snap.keyPressCount == 2)
        #expect(snap.keyCodesRecorded == 1)
    }

    @Test("system events ledger returns rows newest-first and preserves payload")
    func systemEventsNewestFirst() throws {
        let (store, db) = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        try insertRaws(into: db, system: [
            (ts: nowMs - 10_000, category: "foreground_app", payload: "com.apple.dt.Xcode"),
            (ts: nowMs - 5_000,  category: "idle_exit",       payload: nil),
            (ts: nowMs - 1_000,  category: "foreground_app", payload: "com.google.Chrome")
        ])

        let snap = try store.buildPrivacyAuditSnapshot(now: now, windowSeconds: 3600)
        #expect(snap.systemEvents.count == 3)
        #expect(snap.systemEvents.first?.payload == "com.google.Chrome")
        #expect(snap.systemEvents.last?.payload == "com.apple.dt.Xcode")
        #expect(snap.systemEvents[1].category == "idle_exit")
    }

    @Test("snapshot is empty on a fresh database")
    func emptyDatabase() throws {
        let (store, _) = try makeStore()
        let snap = try store.buildPrivacyAuditSnapshot(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(snap.mouseMoveCount == 0)
        #expect(snap.mouseClickCount == 0)
        #expect(snap.keyPressCount == 0)
        #expect(snap.keyCodesRecorded == 0)
        #expect(snap.systemEvents.isEmpty)
    }

    @Test("system events ledger honours the maxSystemEventRows cap")
    func systemEventsRespectLimit() throws {
        let (store, db) = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        var events: [(ts: Int64, category: String, payload: String?)] = []
        for i in 0..<10 {
            events.append((
                ts: nowMs - Int64(i * 1_000) - 1,
                category: "foreground_app",
                payload: "com.example.app\(i)"
            ))
        }
        try insertRaws(into: db, system: events)

        let snap = try store.buildPrivacyAuditSnapshot(
            now: now,
            windowSeconds: 3600,
            maxSystemEventRows: 3
        )
        #expect(snap.systemEvents.count == 3)
        // Newest-first: i=0 has the largest ts.
        #expect(snap.systemEvents.first?.payload == "com.example.app0")
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("EventStore — write operations and read helpers")
struct EventStoreTests {

    private func makeStore() throws -> (EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        return (EventStore(database: db), db)
    }

    @Test("appending an empty batch is a no-op")
    func emptyBatchIsNoop() throws {
        let (store, _) = try makeStore()
        let count = try store.appendBatch([])
        #expect(count == 0)
    }

    @Test("mouse-move write lands in raw_mouse_moves with the right shape")
    func mouseMoveWrite() throws {
        let (store, db) = try makeStore()
        try store.appendBatch([
            .mouseMove(tsMillis: 1_000, displayId: 7, xNorm: 0.25, yNorm: 0.5),
            .mouseMove(tsMillis: 1_050, displayId: 7, xNorm: 0.30, yNorm: 0.6)
        ])
        let rows: [Row] = try db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, display_id, x_norm, y_norm FROM raw_mouse_moves ORDER BY ts")
        }
        #expect(rows.count == 2)
        let first = rows[0]
        #expect((first[0] as? Int64) == 1_000)
        #expect((first[1] as? Int64) == 7)
        #expect((first[2] as? Double) == 0.25)
        #expect((first[3] as? Double) == 0.5)
    }

    @Test("click write encodes button + double-click bit")
    func clickWrite() throws {
        let (store, db) = try makeStore()
        try store.appendBatch([
            .mouseClick(tsMillis: 200, displayId: 1, xNorm: 0.1, yNorm: 0.2, button: .left, isDouble: true),
            .mouseClick(tsMillis: 210, displayId: 1, xNorm: 0.5, yNorm: 0.5, button: .right, isDouble: false)
        ])
        let rows: [Row] = try db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT button, is_double FROM raw_mouse_clicks ORDER BY ts")
        }
        #expect((rows[0][0] as? String) == "left")
        #expect((rows[0][1] as? Int64) == 1)
        #expect((rows[1][0] as? String) == "right")
        #expect((rows[1][1] as? Int64) == 0)
    }

    @Test("key write stores nil keycode as SQL NULL")
    func keyWriteNullCode() throws {
        let (store, db) = try makeStore()
        try store.appendBatch([
            .keyPress(tsMillis: 5, keyCode: nil),
            .keyPress(tsMillis: 6, keyCode: 36)
        ])
        let codes: [Int64?] = try db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key_code FROM raw_key_events ORDER BY ts")
                .map { $0[0] as? Int64 }
        }
        #expect(codes[0] == nil)
        #expect(codes[1] == 36)
    }

    @Test("system event row carries category + payload")
    func systemEventWrite() throws {
        let (store, db) = try makeStore()
        try store.appendBatch([
            .systemEvent(tsMillis: 999, category: "lid_closed", payload: nil),
            .systemEvent(tsMillis: 1_000, category: "foreground_app", payload: "com.apple.Finder")
        ])
        let payloads: [(String, String?)] = try db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT category, payload FROM system_events ORDER BY ts")
                .map { (($0[0] as? String) ?? "", $0[1] as? String) }
        }
        #expect(payloads[0].0 == "lid_closed")
        #expect(payloads[0].1 == nil)
        #expect(payloads[1].0 == "foreground_app")
        #expect(payloads[1].1 == "com.apple.Finder")
    }

    @Test("display snapshot write upserts on (ts, display_id)")
    func displaySnapshotUpsert() throws {
        let (store, db) = try makeStore()
        let info = DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 109, isPrimary: true)
        try store.appendBatch([
            .displaySnapshot(tsMillis: 1_000, info: info),
            .displaySnapshot(tsMillis: 1_000, info: info) // duplicate, INSERT OR REPLACE keeps one
        ])
        let count = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM display_snapshots") ?? 0
        }
        #expect(count == 1)
    }

    @Test("l0Counts reflects total writes across raw tables")
    func l0Counts() throws {
        let (store, _) = try makeStore()
        try store.appendBatch([
            .mouseMove(tsMillis: 1, displayId: 1, xNorm: 0.1, yNorm: 0.1),
            .mouseMove(tsMillis: 2, displayId: 1, xNorm: 0.2, yNorm: 0.2),
            .mouseClick(tsMillis: 3, displayId: 1, xNorm: 0.5, yNorm: 0.5, button: .left, isDouble: false),
            .keyPress(tsMillis: 4, keyCode: nil)
        ])
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 2)
        #expect(counts.mouseClicks == 1)
        #expect(counts.keyEvents == 1)
        #expect(counts.total == 4)
    }

    @Test("latestWriteTimestamp returns the max ts across raw tables and system events")
    func latestWrite() throws {
        let (store, _) = try makeStore()
        try store.appendBatch([
            .mouseMove(tsMillis: 100, displayId: 1, xNorm: 0, yNorm: 0),
            .systemEvent(tsMillis: 999, category: "wake", payload: nil),
            .keyPress(tsMillis: 500, keyCode: nil)
        ])
        let latest = try store.latestWriteTimestamp()
        #expect(latest == 999)
    }

    @Test("latestWriteTimestamp returns nil for an empty database")
    func latestWriteEmpty() throws {
        let (store, _) = try makeStore()
        let latest = try store.latestWriteTimestamp()
        #expect(latest == nil)
    }
}

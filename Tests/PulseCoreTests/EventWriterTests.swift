import Testing
import Foundation
@testable import PulseCore
import PulseTestSupport

@Suite("EventWriter — buffered, batched, atomic writes")
struct EventWriterTests {

    private func makeWriter() throws -> (EventWriter, EventStore, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let displays: @Sendable () -> [DisplayInfo] = { [] }
        let writer = EventWriter(
            store: store,
            displayProvider: displays,
            flushInterval: 1.0,
            maxBufferedEvents: 1_000
        )
        return (writer, store, db)
    }

    @Test("a single enqueue does not write until flushed")
    func enqueueDefersWrite() async throws {
        let (writer, store, _) = try makeWriter()
        let point = NormalizedPoint(displayId: 1, x: 0.1, y: 0.1)
        let event = DomainEvent.mouseMove(point, at: Date(timeIntervalSince1970: 1_000))
        let buffered = await writer.enqueue(event)
        #expect(buffered == 1)
        let preFlush = try store.l0Counts()
        #expect(preFlush.total == 0)
        await writer.flush()
        let postFlush = try store.l0Counts()
        #expect(postFlush.mouseMoves == 1)
    }

    @Test("flush is a no-op when buffer is empty")
    func emptyFlush() async throws {
        let (writer, _, _) = try makeWriter()
        await writer.flush()
        let stats = await writer.snapshot
        #expect(stats.totalFlushes == 1)
        #expect(stats.totalRowsWritten == 0)
    }

    @Test("buffer overflow forces an inline flush")
    func backpressureFlush() async throws {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let displays: @Sendable () -> [DisplayInfo] = { [] }
        let writer = EventWriter(
            store: store,
            displayProvider: displays,
            flushInterval: 60,
            maxBufferedEvents: 5
        )
        for i in 0..<7 {
            let point = NormalizedPoint(displayId: 1, x: 0.1, y: 0.1)
            _ = await writer.enqueue(.mouseMove(point, at: Date(timeIntervalSince1970: TimeInterval(1_000 + i))))
        }
        let counts = try store.l0Counts()
        // At maxBufferedEvents=5, the 5th enqueue triggers a flush. 2 more
        // events sit in the buffer afterwards.
        #expect(counts.mouseMoves == 5)
        #expect(await writer.bufferedCount == 2)
    }

    @Test("system events of every kind translate to the right SQL category")
    func translatesAllSystemKinds() async throws {
        let (writer, _, db) = try makeWriter()
        let now = Date(timeIntervalSince1970: 2_000)
        let cases: [(DomainEvent, String, String?)] = [
            (.foregroundApp(bundleId: "com.apple.Finder", at: now), "foreground_app", "com.apple.Finder"),
            (.windowTitleHash(appBundleId: "com.apple.Safari", titleSHA256: "abc", at: now), "window_title", "com.apple.Safari|abc"),
            (.idleEntered(at: now),    "idle_entered", nil),
            (.idleExited(at: now),     "idle_exited",  nil),
            (.systemSleep(at: now),    "sleep",        nil),
            (.systemWake(at: now),     "wake",         nil),
            (.screenLocked(at: now),   "lock",         nil),
            (.screenUnlocked(at: now), "unlock",       nil),
            (.lidClosed(at: now),      "lid_closed",   nil),
            (.lidOpened(at: now),      "lid_opened",   nil),
            (.powerChanged(isOnBattery: true, percent: 80, at: now), "power", "battery:80"),
            (.displayConfigChanged(at: now), "display_change", nil)
        ]
        for entry in cases {
            _ = await writer.enqueue(entry.0)
        }
        await writer.flush()
        let categories = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT category FROM system_events ORDER BY rowid")
        }
        #expect(categories == cases.map { $0.1 })

        let powerPayload = try db.queue.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT payload FROM system_events WHERE category = 'power' LIMIT 1")
        }
        #expect(powerPayload == "battery:80")
    }

    @Test("display config change fans out one snapshot row per display")
    func displayChangeFanout() async throws {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let displays = [
            DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 109, isPrimary: true),
            DisplayInfo(id: 2, widthPx: 3840, heightPx: 2160, dpi: 163, isPrimary: false)
        ]
        let writer = EventWriter(
            store: store,
            displayProvider: { displays },
            flushInterval: 1,
            maxBufferedEvents: 1_000
        )
        _ = await writer.enqueue(.displayConfigChanged(at: Date(timeIntervalSince1970: 3_000)))
        await writer.flush()
        let count = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM display_snapshots") ?? 0
        }
        #expect(count == 2)
    }
}

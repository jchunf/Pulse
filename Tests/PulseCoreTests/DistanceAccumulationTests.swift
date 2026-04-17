import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("EventWriter — physical distance accumulation into sec_mouse")
struct DistanceAccumulationTests {

    private let display = DisplayInfo(id: 1, widthPx: 1_000, heightPx: 1_000, dpi: 25.4, isPrimary: true)

    private func makeWriter() throws -> (EventWriter, PulseDatabase) {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        // 25.4 DPI → 1 mm per pixel. Makes the math trivial: the distance
        // in mm between two normalized points equals the pixel-space
        // Euclidean distance on a 1000×1000 display.
        let display = display
        let writer = EventWriter(
            store: store,
            displayProvider: { [display] },
            flushInterval: 60,
            maxBufferedEvents: 10_000
        )
        return (writer, db)
    }

    @Test("first mouse move on a display credits no distance (no prior point)")
    func firstMoveNoDistance() async throws {
        let (writer, db) = try makeWriter()
        let p = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        _ = await writer.enqueue(.mouseMove(p, at: Date(timeIntervalSince1970: 1_700_000_000)))
        await writer.flush()
        let distance = try await db.queue.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(distance_mm), 0.0) FROM sec_mouse") ?? 0
        }
        #expect(distance == 0)
    }

    @Test("two moves 300px apart on a 25.4 DPI display credit 300 mm")
    func twoMovesAccumulate() async throws {
        let (writer, db) = try makeWriter()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.0, y: 0.0), at: ts))
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.3, y: 0.4), at: ts))
        await writer.flush()
        // 0.3 * 1000 = 300, 0.4 * 1000 = 400 → hypot = 500 px = 500 mm
        let distance = try await db.queue.read { db in
            try Double.fetchOne(db, sql: "SELECT distance_mm FROM sec_mouse WHERE ts_second = 1700000000") ?? -1
        }
        #expect(abs(distance - 500) < 0.001)
    }

    @Test("moves in different seconds accumulate into separate buckets")
    func bucketsPerSecond() async throws {
        let (writer, db) = try makeWriter()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_001)
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.0, y: 0.0), at: t0))
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.1, y: 0.0), at: t0))
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.2, y: 0.0), at: t1))
        await writer.flush()
        let rows = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT ts_second, distance_mm FROM sec_mouse ORDER BY ts_second")
        }
        #expect(rows.count == 2)
        #expect((rows[0][0] as? Int64) == 1_700_000_000)
        #expect(abs(((rows[0][1] as? Double) ?? 0) - 100) < 0.001) // 0.0→0.1 = 100px = 100mm
        #expect((rows[1][0] as? Int64) == 1_700_000_001)
        #expect(abs(((rows[1][1] as? Double) ?? 0) - 100) < 0.001) // 0.1→0.2 = 100px = 100mm
    }

    @Test("display config change invalidates the last-point cache")
    func displayChangeResetsCache() async throws {
        let (writer, db) = try makeWriter()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.0, y: 0.0), at: ts))
        _ = await writer.enqueue(.displayConfigChanged(at: ts))
        // After reset, this is "first move on display 1" again → no credit.
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.9, y: 0.9), at: ts))
        await writer.flush()
        let distance = try await db.queue.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(distance_mm), 0.0) FROM sec_mouse") ?? 0
        }
        #expect(distance == 0)
    }

    @Test("moves on different displays do not cross-credit distance")
    func perDisplayIsolation() async throws {
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let d1 = DisplayInfo(id: 1, widthPx: 1_000, heightPx: 1_000, dpi: 25.4, isPrimary: true)
        let d2 = DisplayInfo(id: 2, widthPx: 1_000, heightPx: 1_000, dpi: 25.4, isPrimary: false)
        let writer = EventWriter(
            store: store,
            displayProvider: { [d1, d2] },
            flushInterval: 60,
            maxBufferedEvents: 10_000
        )
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        // Seed each display with a first point — no credit.
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.0, y: 0.0), at: ts))
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 2, x: 0.0, y: 0.0), at: ts))
        // Now move on display 1 only; display 2 should not be affected.
        _ = await writer.enqueue(.mouseMove(NormalizedPoint(displayId: 1, x: 0.5, y: 0.0), at: ts))
        await writer.flush()
        let total = try await db.queue.read { db in
            try Double.fetchOne(db, sql: "SELECT distance_mm FROM sec_mouse WHERE ts_second = 1700000000") ?? -1
        }
        #expect(abs(total - 500) < 0.001)
    }
}

import Foundation
import GRDB

/// A typed facade over the GRDB `DatabaseQueue` for the write paths that the
/// collector uses. Keeps SQL out of the runtime files and gives us a single
/// place to evolve the schema (the SQL strings here are the only consumers
/// of column ordering for inserts).
///
/// All writes happen inside transactions; callers batch events into a single
/// `appendBatch(_:)` call to amortize fsync.
public struct EventStore: Sendable {

    private let database: PulseDatabase

    public init(database: PulseDatabase) {
        self.database = database
    }

    /// Persist a batch of write operations atomically. The order matches the
    /// order in `operations`. Returns the count of rows successfully written.
    @discardableResult
    public func appendBatch(_ operations: [WriteOperation]) throws -> Int {
        guard !operations.isEmpty else { return 0 }
        return try database.queue.write { db in
            var count = 0
            for op in operations {
                try op.execute(in: db)
                count += 1
            }
            return count
        }
    }

    // MARK: - Read helpers (used by HealthSnapshot and rollup jobs)

    /// Returns the file size of the database, in bytes, if known. The
    /// in-memory database returns nil. Used by the HealthPanel.
    public func databaseFileSizeBytes() -> Int64? {
        return try? database.queue.read { db in
            let sizeRow = try Row.fetchOne(db, sql: "PRAGMA page_count")
            let pageSizeRow = try Row.fetchOne(db, sql: "PRAGMA page_size")
            guard let pages = sizeRow?[0] as? Int64,
                  let pageSize = pageSizeRow?[0] as? Int64 else {
                return nil
            }
            return pages * pageSize
        }
    }

    /// Counts of L0 rows by table; used as a smoke test in HealthPanel.
    public func l0Counts() throws -> L0Counts {
        try database.queue.read { db in
            let moves = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_mouse_moves") ?? 0
            let clicks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_mouse_clicks") ?? 0
            let keys = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_key_events") ?? 0
            return L0Counts(mouseMoves: moves, mouseClicks: clicks, keyEvents: keys)
        }
    }

    /// Latest write timestamp across L0 tables, in epoch milliseconds. Used
    /// by the HealthPanel to detect "no writes in a while" failures.
    public func latestWriteTimestamp() throws -> Int64? {
        try database.queue.read { db in
            let candidates: [Int64?] = [
                try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM raw_mouse_moves"),
                try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM raw_mouse_clicks"),
                try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM raw_key_events"),
                try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM system_events")
            ]
            return candidates.compactMap { $0 }.max()
        }
    }
}

public struct L0Counts: Sendable, Equatable {
    public let mouseMoves: Int
    public let mouseClicks: Int
    public let keyEvents: Int

    public init(mouseMoves: Int, mouseClicks: Int, keyEvents: Int) {
        self.mouseMoves = mouseMoves
        self.mouseClicks = mouseClicks
        self.keyEvents = keyEvents
    }

    public var total: Int { mouseMoves + mouseClicks + keyEvents }
}

// MARK: - WriteOperation

/// A single, transaction-safe write. We keep this as an enum (rather than a
/// closure) so it can be inspected by tests and so the in-memory writer can
/// reorder/dedupe later if needed.
public enum WriteOperation: Sendable, Equatable {
    case mouseMove(tsMillis: Int64, displayId: UInt32, xNorm: Double, yNorm: Double)
    case mouseClick(tsMillis: Int64, displayId: UInt32, xNorm: Double, yNorm: Double, button: MouseButton, isDouble: Bool)
    case keyPress(tsMillis: Int64, keyCode: UInt16?)
    case systemEvent(tsMillis: Int64, category: String, payload: String?)
    case displaySnapshot(tsMillis: Int64, info: DisplayInfo)
    /// UPSERT a per-second physical distance increment into `sec_mouse`.
    /// Computed by the `EventWriter` from consecutive `NormalizedPoint`
    /// deltas using `MileageConverter`. Accumulates rather than replaces.
    case secMouseDistanceDelta(tsSecond: Int64, mm: Double)

    func execute(in db: Database) throws {
        switch self {
        case let .mouseMove(ts, displayId, x, y):
            try db.execute(
                sql: "INSERT INTO raw_mouse_moves (ts, display_id, x_norm, y_norm) VALUES (?, ?, ?, ?)",
                arguments: [ts, Int64(displayId), x, y]
            )
        case let .mouseClick(ts, displayId, x, y, button, isDouble):
            try db.execute(
                sql: "INSERT INTO raw_mouse_clicks (ts, display_id, x_norm, y_norm, button, is_double) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [ts, Int64(displayId), x, y, button.rawValue, isDouble ? 1 : 0]
            )
        case let .keyPress(ts, keyCode):
            try db.execute(
                sql: "INSERT INTO raw_key_events (ts, key_code) VALUES (?, ?)",
                arguments: [ts, keyCode.map { Int64($0) }]
            )
        case let .systemEvent(ts, category, payload):
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, ?)",
                arguments: [ts, category, payload]
            )
        case let .displaySnapshot(ts, info):
            try db.execute(
                sql: "INSERT OR REPLACE INTO display_snapshots (ts, display_id, width_px, height_px, dpi, is_primary) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [ts, Int64(info.id), info.widthPx, info.heightPx, info.dpi, info.isPrimary ? 1 : 0]
            )
        case let .secMouseDistanceDelta(tsSecond, mm):
            try db.execute(
                sql: """
                    INSERT INTO sec_mouse (ts_second, distance_mm) VALUES (?, ?)
                    ON CONFLICT(ts_second) DO UPDATE SET distance_mm = sec_mouse.distance_mm + excluded.distance_mm
                    """,
                arguments: [tsSecond, mm]
            )
        }
    }
}

import Foundation
import GRDB

/// Thin wrapper around a GRDB `DatabaseQueue` that enforces our defaults
/// (WAL mode, secure delete off for speed, foreign keys on). Callers should
/// obtain the queue via this type rather than instantiating GRDB directly.
public struct PulseDatabase: Sendable {

    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Open (or create) the on-disk Pulse database at the given URL, apply
    /// pragmas, and run all outstanding migrations.
    ///
    /// Pragma tuning notes (round 13):
    ///
    /// - `journal_mode = WAL` (kept) — concurrent reads alongside the
    ///   writer.
    /// - `synchronous = NORMAL` (kept) — durable across application
    ///   crashes; only loses data on a hard power-cut, which our
    ///   rollup pipeline is tolerant of.
    /// - `foreign_keys = ON` (kept) — referential integrity.
    /// - `temp_store = MEMORY` (kept) — sort/aggregation scratch in
    ///   RAM, avoids stat'ing /tmp.
    /// - `cache_size = -65536` (new) — 64 MB page cache (negative
    ///   value means kibibytes). Default is ~2 MB; with the dashboard
    ///   running ~25 read queries every 5 seconds against a small
    ///   handful of hot rollup tables (`hour_summary`, `min_*`,
    ///   `system_events`), 64 MB lets the OS keep all of them
    ///   resident. Memory cost on a typical install is bounded —
    ///   the database tops out around 50–100 MB after months of use,
    ///   most of which is rolled-up summaries we *want* hot.
    /// - `mmap_size = 268435456` (new) — 256 MB memory-map window.
    ///   Lets SQLite read pages directly from the kernel page cache
    ///   without a memcpy into user-space, on the read path. Free
    ///   for processes with virtual address space to spare (which
    ///   on macOS is effectively unlimited per-process).
    public static func open(at url: URL) throws -> PulseDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -65536")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let migrator = try Migrator.bundled()
        _ = try migrator.migrate(queue)
        return PulseDatabase(queue: queue)
    }

    /// Open an in-memory database. Intended for tests.
    public static func inMemory(migrator: Migrator? = nil) throws -> PulseDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        let resolvedMigrator: Migrator = try migrator ?? Migrator.bundled()
        _ = try resolvedMigrator.migrate(queue)
        return PulseDatabase(queue: queue)
    }
}

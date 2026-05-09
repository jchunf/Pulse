import Foundation
import GRDB

/// Thin wrapper around a GRDB connection that enforces our defaults
/// (WAL mode, secure delete off for speed, foreign keys on). The
/// production on-disk path uses `DatabasePool` so concurrent
/// readers (e.g. the dashboard refresh and the menu-bar health
/// snapshot) don't serialize behind each other; the in-memory test
/// path uses `DatabaseQueue` because GRDB's `DatabasePool`
/// requires a real file path on disk for WAL semantics.
///
/// The `queue` property is typed as `any DatabaseWriter` to abstract
/// over both — every read/write site only ever calls `.read { db in }`
/// or `.write { db in }`, both of which the protocol declares.
/// `DatabaseWriter` is itself `Sendable` in GRDB 6+, so this struct
/// inherits the property's Sendability without needing `@unchecked`.
public struct PulseDatabase: Sendable {

    public let queue: any DatabaseWriter

    public init(queue: any DatabaseWriter) {
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
        // Production uses `DatabasePool`: WAL-backed readers can run
        // concurrently with the writer (and with each other), so the
        // dashboard's refresh path doesn't serialize behind any
        // simultaneous menu-bar / writer activity. Round 14 of the
        // perf push.
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let migrator = try Migrator.bundled()
        _ = try migrator.migrate(pool)
        return PulseDatabase(queue: pool)
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

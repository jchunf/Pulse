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
    public static func open(at url: URL) throws -> PulseDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
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

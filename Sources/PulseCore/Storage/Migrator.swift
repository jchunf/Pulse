import Foundation
import GRDB

/// Applies SQL schema migrations to a Pulse database. Each migration is a
/// bundled `.sql` resource named `V{version}__description.sql`.
///
/// Design decisions (see `docs/04-architecture.md#4.5`):
/// - Version tracked via `PRAGMA user_version = N`.
/// - Forward-only. Downgrades are not supported.
/// - Idempotent: re-running the migrator on an up-to-date DB is a no-op.
/// - Each migration runs in its own transaction.
public struct Migrator: Sendable {

    /// A single migration step. Exposed publicly so the app can inject
    /// additional migrations at runtime (e.g. for tests that want minimal
    /// schemas), but the default `allBundledMigrations()` is what
    /// production uses.
    public struct Step: Sendable, Equatable {
        public let version: Int
        public let name: String
        public let sql: String

        public init(version: Int, name: String, sql: String) {
            self.version = version
            self.name = name
            self.sql = sql
        }
    }

    public enum MigrationError: Error, Equatable {
        case bundledResourceMissing(String)
        case unreadableMigration(String, underlying: String)
        case versionConflict(current: Int, requested: Int)
    }

    private let steps: [Step]

    /// Construct a Migrator with an explicit (sorted) list of steps. Prefer
    /// `Migrator.bundled()` in production code.
    public init(steps: [Step]) {
        self.steps = steps.sorted(by: { $0.version < $1.version })
    }

    /// Returns a migrator pre-loaded with every migration bundled in
    /// `PulseCore.Resources/Migrations`. Deterministic ordering by filename.
    public static func bundled() throws -> Migrator {
        let resourceNames = BundledMigrations.resourceNames
        var steps: [Step] = []
        for name in resourceNames {
            guard let url = Bundle.module.url(forResource: name.withoutExtension, withExtension: "sql", subdirectory: "Migrations")
                ?? Bundle.module.url(forResource: name.withoutExtension, withExtension: "sql") else {
                throw MigrationError.bundledResourceMissing(name)
            }
            let sql: String
            do {
                sql = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MigrationError.unreadableMigration(name, underlying: String(describing: error))
            }
            let (version, descriptor) = try BundledMigrations.parseFilename(name)
            steps.append(Step(version: version, name: descriptor, sql: sql))
        }
        return Migrator(steps: steps)
    }

    /// The highest version this migrator will bring a database to.
    public var targetVersion: Int { steps.last?.version ?? 0 }

    /// Apply any outstanding migrations to the given database queue.
    /// Returns the version the database is now at.
    @discardableResult
    public func migrate(_ dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.write { db in
            let current = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            for step in steps where step.version > current {
                try db.execute(sql: step.sql)
                try db.execute(sql: "PRAGMA user_version = \(step.version)")
            }
            return try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
    }
}

/// Inventory of bundled migrations. Kept as a separate enum so tests can
/// assert ordering and parsing rules without needing `Bundle.module`.
enum BundledMigrations {
    /// Every migration filename shipped with PulseCore. Update when adding
    /// a new `V{n}__*.sql` file.
    static let resourceNames: [String] = [
        "V1__initial.sql"
    ]

    /// Parses a filename of the form `V{int}__{name}.sql` into (version, name).
    static func parseFilename(_ filename: String) throws -> (Int, String) {
        let stem = filename.withoutExtension
        guard stem.hasPrefix("V") else {
            throw Migrator.MigrationError.unreadableMigration(
                filename,
                underlying: "expected prefix 'V'"
            )
        }
        let afterV = stem.dropFirst()
        guard let sepRange = afterV.range(of: "__") else {
            throw Migrator.MigrationError.unreadableMigration(
                filename,
                underlying: "expected separator '__'"
            )
        }
        let versionPart = afterV[..<sepRange.lowerBound]
        let namePart = afterV[sepRange.upperBound...]
        guard let version = Int(versionPart) else {
            throw Migrator.MigrationError.unreadableMigration(
                filename,
                underlying: "expected integer after 'V'"
            )
        }
        return (version, String(namePart))
    }
}

private extension String {
    var withoutExtension: String {
        guard let dot = lastIndex(of: ".") else { return self }
        return String(self[..<dot])
    }
}

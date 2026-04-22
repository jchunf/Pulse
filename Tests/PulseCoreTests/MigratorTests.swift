import Testing
import Foundation
import GRDB
@testable import PulseCore

@Suite("Migrator — bundled migrations and schema creation")
struct MigratorTests {

    @Test("filename parser recognizes V1__initial.sql")
    func filenameParsingV1() throws {
        let (version, name) = try BundledMigrations.parseFilename("V1__initial.sql")
        #expect(version == 1)
        #expect(name == "initial")
    }

    @Test("filename parser rejects malformed names")
    func filenameParsingRejectsJunk() {
        let bad = [
            "initial.sql",
            "V.sql",
            "V__missing_digits.sql",
            "X1__wrong_prefix.sql"
        ]
        for name in bad {
            #expect(throws: Migrator.MigrationError.self) {
                _ = try BundledMigrations.parseFilename(name)
            }
        }
    }

    @Test("bundled migrator loads up to V4")
    func bundledMigratorLoads() throws {
        let migrator = try Migrator.bundled()
        #expect(migrator.targetVersion == 4)
    }

    @Test("in-memory database migrated to head has core tables")
    func schemaAppliedInMemory() throws {
        let db = try PulseDatabase.inMemory()
        let tableNames: [String] = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let required = [
            "day_mouse_density",
            "display_snapshots",
            "hour_app",
            "hour_summary",
            "min_app",
            "min_idle",
            "min_key",
            "min_mouse",
            "min_switches",
            "raw_key_events",
            "raw_mouse_clicks",
            "raw_mouse_moves",
            "rollup_watermarks",
            "sec_activity",
            "sec_key",
            "sec_mouse",
            "system_events"
        ]
        for table in required {
            #expect(tableNames.contains(table), "missing table: \(table)")
        }
    }

    @Test("user_version is set to the highest applied migration")
    func userVersionSet() throws {
        let db = try PulseDatabase.inMemory()
        let version: Int? = try db.queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(version == 4)
    }

    @Test("re-running migrator on an up-to-date DB is a no-op")
    func migrationIsIdempotent() throws {
        let db = try PulseDatabase.inMemory()
        let migrator = try Migrator.bundled()
        let version = try migrator.migrate(db.queue)
        #expect(version == 4)
    }

    @Test("V3 adds scroll_ticks to hour_summary")
    func v3AddsScrollTicksColumn() throws {
        let db = try PulseDatabase.inMemory()
        let columns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('hour_summary') ORDER BY cid"
            )
        }
        #expect(columns.contains("scroll_ticks"))
    }

    @Test("V4 creates day_mouse_density with expected columns + PK")
    func v4CreatesDayMouseDensity() throws {
        let db = try PulseDatabase.inMemory()
        let columns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('day_mouse_density') ORDER BY cid"
            )
        }
        #expect(columns == ["day", "display_id", "bin_x", "bin_y", "count"])
    }

    @Test("raw_mouse_moves has expected column shape")
    func rawMouseMovesShape() throws {
        let db = try PulseDatabase.inMemory()
        let columnNames: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('raw_mouse_moves') ORDER BY cid"
            )
        }
        #expect(columnNames == ["ts", "display_id", "x_norm", "y_norm"])
    }
}

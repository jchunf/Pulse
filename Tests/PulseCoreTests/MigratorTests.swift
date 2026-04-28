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

    @Test("bundled migrator loads up to V7")
    func bundledMigratorLoads() throws {
        let migrator = try Migrator.bundled()
        #expect(migrator.targetVersion == 7)
    }

    @Test("in-memory database migrated to head has core tables")
    func schemaAppliedInMemory() throws {
        let db = try PulseDatabase.inMemory()
        let tableNames: [String] = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let required = [
            "day_click_density",
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
            "sec_shortcuts",
            "min_shortcuts",
            "hour_shortcuts",
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
        #expect(version == 7)
    }

    @Test("re-running migrator on an up-to-date DB is a no-op")
    func migrationIsIdempotent() throws {
        let db = try PulseDatabase.inMemory()
        let migrator = try Migrator.bundled()
        let version = try migrator.migrate(db.queue)
        #expect(version == 7)
    }

    @Test("V2 creates rollup_watermarks with the expected shape")
    func v2CreatesRollupWatermarks() throws {
        let db = try PulseDatabase.inMemory()
        let columns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('rollup_watermarks') ORDER BY cid"
            )
        }
        #expect(columns == ["job", "last_processed_ms"])
        // Primary key should be `job` so two writers can't insert
        // duplicate watermarks for the same rollup.
        let pk: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('rollup_watermarks') WHERE pk = 1"
            )
        }
        #expect(pk == ["job"])
    }

    @Test("partial upgrade: V0 → V3, then V3 → head, lands at the same shape as V0 → head")
    func partialUpgradeMatchesFreshUpgrade() throws {
        // First DB: stop at V3, then upgrade the remainder. This is what
        // a returning user on Pulse 1.1 (V3 schema) experiences when
        // they install the latest build.
        let bundled = try Migrator.bundled()
        let throughV3Steps = bundled.steps.filter { $0.version <= 3 }
        let throughV3 = Migrator(steps: throughV3Steps)
        #expect(throughV3.targetVersion == 3)
        let stagedDb = try PulseDatabase.inMemory(migrator: throughV3)
        let interimVersion: Int? = try stagedDb.queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(interimVersion == 3)
        // Now apply the rest.
        _ = try bundled.migrate(stagedDb.queue)
        let finalVersion: Int? = try stagedDb.queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(finalVersion == bundled.targetVersion)

        // Second DB: fresh install, V0 → head in one go.
        let freshDb = try PulseDatabase.inMemory()
        let freshTables: [String] = try freshDb.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let stagedTables: [String] = try stagedDb.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        // The two upgrade paths must converge on the same schema —
        // otherwise a user upgrading from an older Pulse build would
        // end up with a subtly different DB than a fresh install.
        #expect(stagedTables == freshTables)
    }

    @Test("partial upgrade preserves data inserted at the interim version")
    func partialUpgradePreservesData() throws {
        let bundled = try Migrator.bundled()
        let throughV2Steps = bundled.steps.filter { $0.version <= 2 }
        let throughV2 = Migrator(steps: throughV2Steps)
        let db = try PulseDatabase.inMemory(migrator: throughV2)

        // Insert a system_events row at V2 — this represents a real
        // user's data captured before they upgrade.
        try db.queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, ?, ?)",
                arguments: [Int64(1_700_000_000_000), "foreground_app", "com.example.legacy"]
            )
        }

        // Apply remaining migrations.
        _ = try bundled.migrate(db.queue)

        // The pre-existing row should still be there after V3-V7 ran.
        let payload: String? = try db.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload FROM system_events WHERE category = 'foreground_app'"
            )
        }
        #expect(payload == "com.example.legacy")
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

    @Test("V5 creates the three shortcut tables with expected shape")
    func v5CreatesShortcutTables() throws {
        let db = try PulseDatabase.inMemory()
        let tables: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%shortcuts' ORDER BY name"
            )
        }
        #expect(tables == ["hour_shortcuts", "min_shortcuts", "sec_shortcuts"])
        let secColumns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('sec_shortcuts') ORDER BY cid"
            )
        }
        #expect(secColumns == ["ts_second", "combo", "count"])
    }

    @Test("V6 creates day_key_codes with expected shape")
    func v6CreatesDayKeyCodes() throws {
        let db = try PulseDatabase.inMemory()
        let columns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('day_key_codes') ORDER BY cid"
            )
        }
        #expect(columns == ["day", "key_code", "count"])
    }

    @Test("V7 creates day_click_density with expected shape (mirrors V4)")
    func v7CreatesDayClickDensity() throws {
        let db = try PulseDatabase.inMemory()
        let columns: [String] = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('day_click_density') ORDER BY cid"
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

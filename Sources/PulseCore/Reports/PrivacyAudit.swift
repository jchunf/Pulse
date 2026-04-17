import Foundation
import GRDB

/// A user-facing snapshot of what Pulse has actually written to its
/// local SQLite in a bounded recent window. Used by the Settings
/// "Show what Pulse has recorded" button to turn the `05-privacy.md`
/// claims into something the user can verify in-app — the row counts
/// and the system-event ledger come directly off disk, nothing derived
/// or aggregated.
///
/// Deliberately raw:
/// - Mouse-move / click counts only (no coordinates).
/// - Key-press count and a separate `keyCodesRecorded` count so the
///   default-opt-out of key codes is observable ("0 key codes stored").
/// - The full `system_events` ledger for the window, so the user sees
///   every app switch, idle transition, lid / power event.
public struct PrivacyAuditSnapshot: Sendable, Equatable {

    public struct SystemEventRow: Sendable, Equatable {
        public let timestamp: Date
        public let category: String
        public let payload: String?

        public init(timestamp: Date, category: String, payload: String?) {
            self.timestamp = timestamp
            self.category = category
            self.payload = payload
        }
    }

    public let windowStart: Date
    public let windowEnd: Date
    public let mouseMoveCount: Int
    public let mouseClickCount: Int
    public let keyPressCount: Int
    /// Count of raw key-press rows whose `key_code` column is non-null.
    /// Should be 0 in the default (privacy-first) configuration; shown
    /// in the audit window so the user can confirm.
    public let keyCodesRecorded: Int
    public let systemEvents: [SystemEventRow]

    public init(
        windowStart: Date,
        windowEnd: Date,
        mouseMoveCount: Int,
        mouseClickCount: Int,
        keyPressCount: Int,
        keyCodesRecorded: Int,
        systemEvents: [SystemEventRow]
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.mouseMoveCount = mouseMoveCount
        self.mouseClickCount = mouseClickCount
        self.keyPressCount = keyPressCount
        self.keyCodesRecorded = keyCodesRecorded
        self.systemEvents = systemEvents
    }
}

public extension EventStore {

    /// Reads the raw tables for the last `windowSeconds` seconds ending
    /// at `now` and returns a `PrivacyAuditSnapshot`. Caps the number of
    /// returned `system_events` rows to `maxSystemEventRows` so a very
    /// active user's recent history stays renderable in the window.
    func buildPrivacyAuditSnapshot(
        now: Date = Date(),
        windowSeconds: TimeInterval = 3600,
        maxSystemEventRows: Int = 500
    ) throws -> PrivacyAuditSnapshot {
        precondition(windowSeconds > 0, "windowSeconds must be > 0")
        let windowStart = now.addingTimeInterval(-windowSeconds)
        let startMs = Int64(windowStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(now.timeIntervalSince1970 * 1_000)

        return try database.queue.read { db in
            let moves = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_mouse_moves WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
            let clicks = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_mouse_clicks WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
            let keys = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_key_events WHERE ts >= ? AND ts < ?
                """, arguments: [startMs, endMs]) ?? 0
            let keyCodes = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM raw_key_events
                WHERE ts >= ? AND ts < ? AND key_code IS NOT NULL
                """, arguments: [startMs, endMs]) ?? 0

            var events: [PrivacyAuditSnapshot.SystemEventRow] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT ts, category, payload FROM system_events
                WHERE ts >= ? AND ts < ?
                ORDER BY ts DESC
                LIMIT ?
                """, arguments: [startMs, endMs, maxSystemEventRows]) {
                let ts: Int64 = row["ts"]
                let category: String = row["category"]
                let payload: String? = row["payload"]
                events.append(PrivacyAuditSnapshot.SystemEventRow(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1_000),
                    category: category,
                    payload: payload
                ))
            }

            return PrivacyAuditSnapshot(
                windowStart: windowStart,
                windowEnd: now,
                mouseMoveCount: moves,
                mouseClickCount: clicks,
                keyPressCount: keys,
                keyCodesRecorded: keyCodes,
                systemEvents: events
            )
        }
    }
}

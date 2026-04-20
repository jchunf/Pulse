import Foundation
import GRDB

/// F-47 — user-initiated deletion of every row whose timestamp falls
/// in `[start, end)`, across all data tables. A destructive action
/// framed by the Settings panel with a two-click confirmation flow.
///
/// Scope: deletes rows in the L0 raw streams, L1 / L2 / L3
/// aggregates, `system_events`, and `display_snapshots`. Does **not**
/// touch `rollup_watermarks` — those represent processing progress,
/// not stored user data; leaving them intact means the next rollup
/// tick picks up normally from whatever post-purge events arrive.
///
/// Immediately after the deletes, the method writes a single
/// `data_purged` system event at `auditedAt` (usually `Date()` at
/// call time) with a `"startMs-endMs"` payload. This survives the
/// purge because `auditedAt` is expected to be outside the purged
/// range (caller enforces this). The entry gives the user's
/// privacy-audit window proof that a purge happened without
/// preserving any of the purged rows.
///
/// Known soft-edge: `system_events.foreground_app` transitions
/// before the range remain intact, so the Dashboard's timeline /
/// app-ranking queries will stretch the last-pre-range bundle across
/// the gap. That's a presentational artifact, not data re-creation
/// — the underlying events are gone. Users who want to cap the
/// stretch can purge the adjacent minute as well.
public extension EventStore {

    @discardableResult
    func purgeRange(
        start: Date,
        end: Date,
        auditedAt: Date = Date()
    ) throws -> RangePurgeResult {
        precondition(end > start, "end must be strictly after start")
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(end.timeIntervalSince1970 * 1_000)
        let startSec = Int64(start.timeIntervalSince1970)
        let endSec = Int64(end.timeIntervalSince1970)
        let auditMs = Int64(auditedAt.timeIntervalSince1970 * 1_000)

        var totalDeleted = 0
        try database.queue.write { db in
            for sql in Self.msRangeDeletes {
                try db.execute(sql: sql, arguments: [startMs, endMs])
                totalDeleted += try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            }
            for sql in Self.secRangeDeletes {
                try db.execute(sql: sql, arguments: [startSec, endSec])
                totalDeleted += try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            }
            // Audit row. Must land outside [start, end) so it's not
            // immediately re-purged on the next call; caller passes
            // `Date()` by default which is always >= end in practice.
            let payload = "\(startMs)-\(endMs)"
            try db.execute(
                sql: "INSERT INTO system_events (ts, category, payload) VALUES (?, 'data_purged', ?)",
                arguments: [auditMs, payload]
            )
        }

        return RangePurgeResult(
            rangeStart: start,
            rangeEnd: end,
            deletedRowCount: totalDeleted,
            auditedAt: auditedAt
        )
    }

    /// Tables keyed on millisecond timestamps.
    private static let msRangeDeletes: [String] = [
        "DELETE FROM raw_mouse_moves   WHERE ts >= ? AND ts < ?",
        "DELETE FROM raw_mouse_clicks  WHERE ts >= ? AND ts < ?",
        "DELETE FROM raw_key_events    WHERE ts >= ? AND ts < ?",
        "DELETE FROM system_events     WHERE ts >= ? AND ts < ?",
        "DELETE FROM display_snapshots WHERE ts >= ? AND ts < ?"
    ]

    /// Tables keyed on second-resolution timestamps (second / minute
    /// / hour buckets all use second-epoch integers).
    private static let secRangeDeletes: [String] = [
        "DELETE FROM sec_mouse     WHERE ts_second >= ? AND ts_second < ?",
        "DELETE FROM sec_key       WHERE ts_second >= ? AND ts_second < ?",
        "DELETE FROM sec_activity  WHERE ts_second >= ? AND ts_second < ?",
        "DELETE FROM min_mouse     WHERE ts_minute >= ? AND ts_minute < ?",
        "DELETE FROM min_key       WHERE ts_minute >= ? AND ts_minute < ?",
        "DELETE FROM min_app       WHERE ts_minute >= ? AND ts_minute < ?",
        "DELETE FROM min_switches  WHERE ts_minute >= ? AND ts_minute < ?",
        "DELETE FROM min_idle      WHERE ts_minute >= ? AND ts_minute < ?",
        "DELETE FROM hour_app      WHERE ts_hour   >= ? AND ts_hour   < ?",
        "DELETE FROM hour_summary  WHERE ts_hour   >= ? AND ts_hour   < ?"
    ]
}

// MARK: - Value type

public struct RangePurgeResult: Sendable, Equatable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let deletedRowCount: Int
    public let auditedAt: Date

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        deletedRowCount: Int,
        auditedAt: Date
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.deletedRowCount = deletedRowCount
        self.auditedAt = auditedAt
    }
}

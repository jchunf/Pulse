import Foundation
import GRDB

/// F-10 — a full-day horizontal band showing which app had focus at
/// each moment. Walks `system_events.foreground_app` transitions
/// for `day` (plus the last transition before `dayStart` as a
/// "prior bundle" carry-over), and emits contiguous, non-overlapping
/// `DayTimelineSegment`s. The tail segment closes at `capUntil` —
/// that's "now" for today, or the end of the day for a historic
/// lookup — so the UI can draw a partial bar on today's in-progress
/// slot rather than waiting for the day to end.
///
/// `system_events` is the permanent source of truth for foreground
/// transitions (it is **not** touched by `purgeExpired`), so this
/// query is stable across the rollup layers. No coordination with
/// `min_app` is required.
public extension EventStore {

    func dayTimeline(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DayTimeline {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        guard endCap > dayStart else {
            return DayTimeline(dayStart: dayStart, dayEnd: dayStart, segments: [])
        }

        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endCap.timeIntervalSince1970 * 1_000)

        // Fetch the prior-day carry-over + today's transitions in one
        // read transaction so the UI sees a consistent snapshot.
        let (events, priorBundle) = try database.queue.read { db -> ([(Int64, String)], String?) in
            let prior = try String.fetchOne(db, sql: """
                SELECT payload FROM system_events
                WHERE category = 'foreground_app' AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [startMs])
            let rows: [(Int64, String)] = try Row.fetchAll(db, sql: """
                SELECT ts, payload FROM system_events
                WHERE category = 'foreground_app' AND ts >= ? AND ts < ?
                ORDER BY ts, rowid
                """, arguments: [startMs, endMs]).map { row in
                (row["ts"] as Int64, row["payload"] as String)
            }
            return (rows, prior)
        }

        var segments: [DayTimelineSegment] = []
        var currentStartMs = startMs
        var currentBundle = priorBundle
        for (ts, bundle) in events {
            if let current = currentBundle, ts > currentStartMs {
                segments.append(Self.segment(startMs: currentStartMs, endMs: ts, bundleId: current))
            }
            currentStartMs = ts
            currentBundle = bundle
        }
        // Tail segment ending at capUntil.
        if let current = currentBundle, endMs > currentStartMs {
            segments.append(Self.segment(startMs: currentStartMs, endMs: endMs, bundleId: current))
        }

        return DayTimeline(dayStart: dayStart, dayEnd: endCap, segments: segments)
    }

    private static func segment(startMs: Int64, endMs: Int64, bundleId: String) -> DayTimelineSegment {
        DayTimelineSegment(
            bundleId: bundleId,
            startedAt: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0),
            endedAt: Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)
        )
    }
}

// MARK: - Value types

public struct DayTimelineSegment: Sendable, Equatable {
    public let bundleId: String
    public let startedAt: Date
    public let endedAt: Date

    public init(bundleId: String, startedAt: Date, endedAt: Date) {
        self.bundleId = bundleId
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var durationSeconds: Int {
        Int(endedAt.timeIntervalSince(startedAt))
    }
}

/// A whole-day focus timeline. `dayStart` is the local start-of-day
/// and `dayEnd` is the truncation point (either end-of-day for a
/// historical day or "now" for today). UI draws the 24h axis from
/// `dayStart` to `dayStart + 86_400` and leaves the trailing
/// `dayEnd → dayStart + 86_400` visually empty — the user shouldn't
/// see a stretched 15h bar on a 15h-of-today timeline.
public struct DayTimeline: Sendable, Equatable {
    public let dayStart: Date
    public let dayEnd: Date
    public let segments: [DayTimelineSegment]

    public init(dayStart: Date, dayEnd: Date, segments: [DayTimelineSegment]) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.segments = segments
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Returns segments sorted by `durationSeconds` descending, without
    /// merging adjacencies. UI can use this to pick the top-N bundles
    /// for a compact legend.
    public func topBundles(limit: Int = 5) -> [(bundleId: String, totalSeconds: Int)] {
        var totals: [String: Int] = [:]
        for segment in segments {
            totals[segment.bundleId, default: 0] += segment.durationSeconds
        }
        return totals
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (bundleId: $0.key, totalSeconds: $0.value) }
    }
}

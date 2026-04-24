import Foundation
import GRDB

/// F-22 — "被动消费时长": time the user had an app foregrounded with
/// the screen on but logged no input events. Captures "I watched a
/// video for 30 minutes" or "I was reading a long article" as distinct
/// from "I walked away from the desk" (lock / sleep / lid_closed) or
/// pure active use.
///
/// Derivation:
/// 1. Walk `idle_entered` / `idle_exited` pairs for the day (same as
///    `restSegments`, but inline — we need to merge against other
///    system_events in one pass).
/// 2. For each idle interval, subtract any overlap with a screen-off
///    interval: `lock` / `unlock`, `sleep` / `wake`, `lid_closed` /
///    `lid_opened` windows all count as "screen off / user clearly
///    away". A session still open at `capUntil` closes at the cap.
/// 3. For each remaining screen-on idle sub-segment, attribute the
///    duration to whichever bundle was foregrounded when the sub-
///    segment started (last `foreground_app` ≤ start).
///
/// The output is the aggregate day total plus the top-attributed
/// bundle so the Dashboard card can tell a one-line story.
public extension EventStore {

    func passiveConsumption(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> PassiveConsumption {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        guard endCap > dayStart else { return .empty }

        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endCap.timeIntervalSince1970 * 1_000)

        // One scan over system_events — we need idle pairs + screen-off
        // pairs + foreground_app lookups all from the same table, so
        // pulling them once and filtering in-memory is cheaper than
        // three separate queries.
        let events: [(Int64, String, String?)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, category, payload FROM system_events
                WHERE ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [startMs, endMs]).map { row in
                (row["ts"] as Int64, row["category"] as String, row["payload"] as String?)
            }
        }

        // One additional query — the foreground_app that was active at
        // dayStart (the most recent one before the day began). Lets us
        // attribute passive minutes that begin before the first
        // in-window foreground_app event.
        let priorBundle: String? = try database.queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT payload FROM system_events
                WHERE category = 'foreground_app' AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [startMs])
        }

        let idleIntervals = pairUp(events: events, start: "idle_entered",
                                   end: "idle_exited", endCapMs: endMs)
        let screenOffIntervals =
            pairUp(events: events, start: "lock",        end: "unlock",     endCapMs: endMs) +
            pairUp(events: events, start: "sleep",       end: "wake",       endCapMs: endMs) +
            pairUp(events: events, start: "lid_closed",  end: "lid_opened", endCapMs: endMs)

        let screenOnIdle = subtract(idleIntervals, minus: screenOffIntervals)

        // Collect foreground_app transitions for in-range lookups.
        var fgTransitions: [(Int64, String)] = []
        for (ts, category, payload) in events
            where category == "foreground_app" {
            if let bundle = payload {
                fgTransitions.append((ts, bundle))
            }
        }

        var segments: [PassiveSegment] = []
        for interval in screenOnIdle {
            // Attribute to the bundle active at interval.start.
            let bundle = bundleActive(at: interval.0, transitions: fgTransitions,
                                      priorBundle: priorBundle)
            guard let bundle else { continue }
            // Drop system shells that aren't meaningful for a
            // "what were you consuming?" story — same exclusion set
            // `appUsageRanking` uses so totals stay consistent.
            if SystemAppFilter.excludedBundles.contains(bundle) { continue }
            segments.append(PassiveSegment(
                startedAt: Date(timeIntervalSince1970: TimeInterval(interval.0) / 1_000),
                endedAt:   Date(timeIntervalSince1970: TimeInterval(interval.1) / 1_000),
                bundleId:  bundle
            ))
        }

        return PassiveConsumption(segments: segments)
    }
}

// MARK: - Interval helpers

private func pairUp(
    events: [(Int64, String, String?)],
    start: String,
    end: String,
    endCapMs: Int64
) -> [(Int64, Int64)] {
    var pairs: [(Int64, Int64)] = []
    var openStart: Int64? = nil
    for (ts, category, _) in events {
        if category == start {
            openStart = ts
        } else if category == end, let s = openStart, ts > s {
            pairs.append((s, ts))
            openStart = nil
        }
    }
    if let s = openStart, endCapMs > s {
        pairs.append((s, endCapMs))
    }
    return pairs
}

/// `a` minus `b` on the integer-millisecond number line — returns the
/// intervals in `a` that don't overlap anything in `b`. `b` is
/// normalised (merged + sorted) to keep the subtraction loop simple.
private func subtract(
    _ a: [(Int64, Int64)],
    minus b: [(Int64, Int64)]
) -> [(Int64, Int64)] {
    guard !b.isEmpty else { return a }
    let merged = mergeIntervals(b)
    var out: [(Int64, Int64)] = []
    for segment in a {
        var cursor = segment.0
        let end = segment.1
        for block in merged {
            if block.1 <= cursor { continue }
            if block.0 >= end { break }
            if block.0 > cursor {
                out.append((cursor, min(block.0, end)))
            }
            cursor = max(cursor, block.1)
            if cursor >= end { break }
        }
        if cursor < end {
            out.append((cursor, end))
        }
    }
    return out
}

private func mergeIntervals(_ intervals: [(Int64, Int64)]) -> [(Int64, Int64)] {
    let sorted = intervals.sorted { $0.0 < $1.0 }
    var out: [(Int64, Int64)] = []
    for interval in sorted {
        if let last = out.last, last.1 >= interval.0 {
            out[out.count - 1] = (last.0, max(last.1, interval.1))
        } else {
            out.append(interval)
        }
    }
    return out
}

/// Returns the bundleId most recently foregrounded at or before
/// `tsMs`. Falls back to `priorBundle` (the bundle active at
/// day-start) when no in-range transition has happened yet.
private func bundleActive(
    at tsMs: Int64,
    transitions: [(Int64, String)],
    priorBundle: String?
) -> String? {
    var active = priorBundle
    for (ts, bundle) in transitions {
        if ts > tsMs { break }
        active = bundle
    }
    return active
}

// MARK: - Value types

public struct PassiveSegment: Sendable, Equatable {
    public let startedAt: Date
    public let endedAt: Date
    public let bundleId: String

    public init(startedAt: Date, endedAt: Date, bundleId: String) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleId = bundleId
    }

    public var durationSeconds: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }
}

public struct PassiveConsumption: Sendable, Equatable {
    public let segments: [PassiveSegment]

    public init(segments: [PassiveSegment]) {
        self.segments = segments
    }

    public static let empty = PassiveConsumption(segments: [])

    public var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    /// The bundle that carried the most passive time today, with the
    /// seconds attributed to it. `nil` when there's no passive time.
    public var topBundle: (bundleId: String, seconds: Int)? {
        var totals: [String: Int] = [:]
        for segment in segments {
            totals[segment.bundleId, default: 0] += segment.durationSeconds
        }
        guard let best = totals.max(by: { $0.value < $1.value }) else {
            return nil
        }
        return (best.key, best.value)
    }
}

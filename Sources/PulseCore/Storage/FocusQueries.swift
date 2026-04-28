import Foundation
import GRDB

/// F-37 — read-side queries over the macOS Focus / Do-Not-Disturb
/// signal. The collector (`FocusObserver` in `PulsePlatform`) emits
/// `focus_on` / `focus_off` rows into `system_events`; the queries
/// here pair them up into intervals and roll the durations into
/// daily totals.
///
/// "Focus" here is the umbrella for Apple's Focus modes (Work,
/// Personal, Sleep, …) plus the legacy Do-Not-Disturb signal — anything
/// that says "the user has explicitly told the system 'I'm
/// concentrating'". Total Focus seconds per day is the headline
/// number; mode-name breakdown is preserved in payload but not yet
/// surfaced on the dashboard (parked for a v2.x mode-detail card).
///
/// Open intervals (a `focus_on` with no matching `focus_off`) are
/// clamped at `capUntil` — same convention `dayTimeline` uses for the
/// in-progress today-segment.
public extension EventStore {

    /// Total seconds spent in Focus on the local calendar day
    /// containing `day`. Open intervals (Focus still on) clamp at
    /// `capUntil` so "today" returns the live in-progress total.
    func dailyFocusSeconds(
        on day: Date,
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Int {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let endCap = min(capUntil, dayEnd)
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endCapMs = Int64(endCap.timeIntervalSince1970 * 1_000)
        let dayEndMs = Int64(dayEnd.timeIntervalSince1970 * 1_000)
        guard endCapMs > startMs else { return 0 }

        // Pull the focus_on / focus_off rows whose timestamp is
        // either inside the day OR is the LAST focus_on event before
        // the day began (so a Focus state that started at 23:50
        // yesterday still credits seconds inside today's window).
        let rows: [(Int64, String)] = try database.queue.read { db in
            // 1) The most recent event strictly before the window.
            //    Used to determine the "starting state" of the window.
            let priorRow: Row? = try Row.fetchOne(db, sql: """
                SELECT ts, category FROM system_events
                WHERE category IN ('focus_on', 'focus_off') AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [startMs])
            // 2) Every event inside the window, ascending.
            let windowRows = try Row.fetchAll(db, sql: """
                SELECT ts, category FROM system_events
                WHERE category IN ('focus_on', 'focus_off')
                  AND ts >= ? AND ts < ?
                ORDER BY ts ASC
                """, arguments: [startMs, dayEndMs])
            var out: [(Int64, String)] = []
            if let r = priorRow {
                let ts: Int64 = r["ts"]
                let cat: String = r["category"]
                out.append((ts, cat))
            }
            for r in windowRows {
                let ts: Int64 = r["ts"]
                let cat: String = r["category"]
                out.append((ts, cat))
            }
            return out
        }

        // Walk the rows. Track current state (in-focus vs not) and
        // the timestamp at which it started. Accumulate inside the
        // window, clamped to [startMs, endCapMs].
        var inFocus = false
        var stateStart: Int64 = startMs
        var seconds: Int = 0
        for (ts, category) in rows {
            // A "prior" row (ts < startMs) just initialises state —
            // doesn't accumulate yet. We clamp its effective start
            // to startMs.
            if ts < startMs {
                inFocus = (category == "focus_on")
                stateStart = startMs
                continue
            }
            let clampedTs = min(ts, endCapMs)
            if inFocus {
                seconds += Int(max(0, (clampedTs - stateStart) / 1_000))
            }
            inFocus = (category == "focus_on")
            stateStart = clampedTs
            if clampedTs >= endCapMs { break }
        }
        // Close the trailing interval at `endCap` if Focus is still on.
        if inFocus && stateStart < endCapMs {
            seconds += Int(max(0, (endCapMs - stateStart) / 1_000))
        }
        return seconds
    }

    /// Fraction of `[dayStart, capUntil)` spent in Focus. Returns
    /// `0` for an empty / unbounded window. Used as the headline
    /// number on the dashboard tile ("you've been in Focus 38%
    /// of today so far").
    func focusFractionToday(
        on day: Date = Date(),
        capUntil: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Double {
        let dayStart = calendar.startOfDay(for: day)
        let elapsed = capUntil.timeIntervalSince(dayStart)
        guard elapsed > 0 else { return 0 }
        let secs = try dailyFocusSeconds(on: day, capUntil: capUntil, calendar: calendar)
        return Double(secs) / elapsed
    }
}

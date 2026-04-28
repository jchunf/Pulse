import Foundation
import GRDB

/// F-19 — typing-cadence sparkline over a recent window. The roadmap
/// originally framed this as inter-keystroke interval analysis, but
/// `raw_key_events` is purged at rollup time so sub-second intervals
/// don't survive past `rollRawToSecond`. The closest signal we can
/// preserve from `min_key` is the shape of typing intensity over time
/// — a 60-element vector of presses-per-minute reads as a "rhythm"
/// just as well, and it's pure derivation (no collector or migration
/// changes).
public extension EventStore {

    /// Returns one entry per minute inside `[endingAt - minutes,
    /// endingAt)`. Every minute in the window is represented; minutes
    /// with no rolled-up activity surface as `pressCount = 0` so the
    /// caller can render gaps verbatim.
    func keyboardRhythm(
        endingAt: Date,
        minutes: Int = 60
    ) throws -> KeyboardRhythm {
        precondition(minutes >= 1, "minutes must be at least 1")
        // `min_key.ts_minute` is the start-of-minute epoch *seconds*.
        let endMinute = Int64(endingAt.timeIntervalSince1970 / 60) * 60
        let startMinute = endMinute - Int64(minutes) * 60

        let rows: [(Int64, Int)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts_minute, press_count
                FROM min_key
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startMinute, endMinute])
                .map { row in
                    let ts: Int64 = row["ts_minute"]
                    let count: Int = row["press_count"] ?? 0
                    return (ts, count)
                }
        }
        let perMinute: [Int64: Int] = Dictionary(uniqueKeysWithValues: rows)

        var samples: [KeyboardRhythm.Sample] = []
        samples.reserveCapacity(minutes)
        for offset in 0..<minutes {
            let minuteStart = startMinute + Int64(offset) * 60
            samples.append(
                KeyboardRhythm.Sample(
                    minuteStart: Date(timeIntervalSince1970: TimeInterval(minuteStart)),
                    pressCount: perMinute[minuteStart] ?? 0
                )
            )
        }
        return KeyboardRhythm(samples: samples)
    }
}

/// One rolling window of typing activity — chronologically-ordered
/// per-minute press counts, plus convenience aggregates the card uses
/// for its hero numbers.
public struct KeyboardRhythm: Sendable, Equatable {
    public struct Sample: Sendable, Equatable, Identifiable {
        public let minuteStart: Date
        public let pressCount: Int
        public var id: Date { minuteStart }
        public init(minuteStart: Date, pressCount: Int) {
            self.minuteStart = minuteStart
            self.pressCount = pressCount
        }
    }

    public let samples: [Sample]

    public init(samples: [Sample]) {
        self.samples = samples
    }

    /// Peak KPM observed in the window. Same metric as F-12 but the
    /// window is 60 minutes here, not "today".
    public var peakKPM: Int {
        samples.map(\.pressCount).max() ?? 0
    }

    /// Average KPM across active minutes only — minutes with zero
    /// presses don't drag the average down. Returns `0` when no
    /// minute had any activity.
    public var avgKPMActive: Double {
        let active = samples.filter { $0.pressCount > 0 }
        guard !active.isEmpty else { return 0 }
        return Double(active.reduce(0) { $0 + $1.pressCount }) / Double(active.count)
    }

    public var totalPresses: Int {
        samples.reduce(0) { $0 + $1.pressCount }
    }
}

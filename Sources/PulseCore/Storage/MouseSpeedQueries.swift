import Foundation
import GRDB

/// F-18 — per-minute mouse-speed sparkline. Speed = `distance_mm /
/// 60` (mm/sec) for each minute that recorded any movement; idle
/// minutes drop to zero so the gaps are visible. Pulled from the
/// existing `min_mouse` rollup — no new collector or migration.
public extension EventStore {

    /// One sample per minute over `[endingAt - minutes, endingAt)`,
    /// in chronological order. Minutes with zero `move_events` get
    /// `mmPerSecond = 0` rather than being skipped.
    func mouseSpeed(
        endingAt: Date,
        minutes: Int = 60
    ) throws -> MouseSpeedRhythm {
        precondition(minutes >= 1, "minutes must be at least 1")
        // `min_mouse.ts_minute` is the start-of-minute epoch *seconds*.
        let endMinute = Int64(endingAt.timeIntervalSince1970 / 60) * 60
        let startMinute = endMinute - Int64(minutes) * 60

        let rows: [(Int64, Double, Int)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts_minute, distance_mm, move_events
                FROM min_mouse
                WHERE ts_minute >= ? AND ts_minute < ?
                """, arguments: [startMinute, endMinute])
                .map { row in
                    let ts: Int64 = row["ts_minute"]
                    let mm: Double = row["distance_mm"] ?? 0
                    let moves: Int = row["move_events"] ?? 0
                    return (ts, mm, moves)
                }
        }
        let perMinute: [Int64: (mm: Double, moves: Int)] = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2)) }
        )

        var samples: [MouseSpeedRhythm.Sample] = []
        samples.reserveCapacity(minutes)
        for offset in 0..<minutes {
            let minuteStart = startMinute + Int64(offset) * 60
            let entry = perMinute[minuteStart]
            // Average over the WHOLE minute (60s) — minutes with brief
            // bursts but mostly idle still read as low average speed
            // rather than artificially-high "speed during the moves
            // only". This matches what the user perceives: slow
            // typing-aware browsing != fast burst gestures.
            let mmPerSecond = (entry?.mm ?? 0) / 60.0
            samples.append(
                MouseSpeedRhythm.Sample(
                    minuteStart: Date(timeIntervalSince1970: TimeInterval(minuteStart)),
                    mmPerSecond: mmPerSecond,
                    moveEvents: entry?.moves ?? 0
                )
            )
        }
        return MouseSpeedRhythm(samples: samples)
    }
}

/// Per-minute mouse speed series for the Input pane sparkline.
public struct MouseSpeedRhythm: Sendable, Equatable {
    public struct Sample: Sendable, Equatable, Identifiable {
        public let minuteStart: Date
        /// Average speed in millimetres per second across the minute.
        public let mmPerSecond: Double
        /// Raw move-event count; included so a future "movement
        /// volume" chart can read the same sample.
        public let moveEvents: Int

        public var id: Date { minuteStart }
        public init(minuteStart: Date, mmPerSecond: Double, moveEvents: Int) {
            self.minuteStart = minuteStart
            self.mmPerSecond = mmPerSecond
            self.moveEvents = moveEvents
        }
    }

    public let samples: [Sample]

    public init(samples: [Sample]) {
        self.samples = samples
    }

    public var peakMmPerSecond: Double {
        samples.map(\.mmPerSecond).max() ?? 0
    }

    /// Average mm/s across active minutes only — quiet minutes don't
    /// drag the figure. Returns `0` when no minute had any motion.
    public var avgMmPerSecondActive: Double {
        let active = samples.filter { $0.mmPerSecond > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.mmPerSecond } / Double(active.count)
    }

    public var totalMoveEvents: Int {
        samples.reduce(0) { $0 + $1.moveEvents }
    }
}

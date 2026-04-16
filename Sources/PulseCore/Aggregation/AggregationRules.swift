import Foundation

/// Pure rules that drive the rollup jobs described in
/// `docs/03-data-collection.md#四`. Kept as free-function-style statics so
/// tests can exercise them without spinning up a database.
///
/// Time bucket conventions:
/// - Everything is UTC epoch seconds (or milliseconds) internally.
/// - A "second bucket" is the floor of the Unix timestamp in seconds.
/// - A "minute bucket" is the floor divided by 60.
/// - An "hour bucket" is the floor divided by 3600.
/// Timezone-independent: we never bucket on local wall time here. Local-time
/// presentation is the UI's responsibility.
public enum AggregationRules {

    /// Floor `instant` to the start of its second bucket.
    public static func secondBucket(for instant: Date) -> Date {
        Date(timeIntervalSince1970: floor(instant.timeIntervalSince1970))
    }

    /// Floor `instant` to the start of its minute bucket.
    public static func minuteBucket(for instant: Date) -> Date {
        let secs = floor(instant.timeIntervalSince1970 / 60.0) * 60.0
        return Date(timeIntervalSince1970: secs)
    }

    /// Floor `instant` to the start of its hour bucket.
    public static func hourBucket(for instant: Date) -> Date {
        let secs = floor(instant.timeIntervalSince1970 / 3_600.0) * 3_600.0
        return Date(timeIntervalSince1970: secs)
    }

    /// Floor `instant` to the start of its day bucket, in UTC.
    public static func utcDayBucket(for instant: Date) -> Date {
        let secs = floor(instant.timeIntervalSince1970 / 86_400.0) * 86_400.0
        return Date(timeIntervalSince1970: secs)
    }

    /// Retention boundaries (in seconds). See `docs/03-data-collection.md#二`.
    public enum Retention {
        public static let rawSeconds: TimeInterval = 14 * 86_400     // 14 days
        public static let secondLayer: TimeInterval = 30 * 86_400    // 30 days
        public static let minuteLayer: TimeInterval = 365 * 86_400   // 1 year
        // hour layer: permanent
    }

    /// Returns the cutoff instant beyond which raw (L0) rows should be purged
    /// at the given `now`. Rows with timestamps strictly earlier than this
    /// cutoff are expired.
    public static func rawCutoff(at now: Date) -> Date {
        now.addingTimeInterval(-Retention.rawSeconds)
    }

    /// Similar cutoff for the L1 (second) layer.
    public static func secondLayerCutoff(at now: Date) -> Date {
        now.addingTimeInterval(-Retention.secondLayer)
    }

    /// Similar cutoff for the L2 (minute) layer.
    public static func minuteLayerCutoff(at now: Date) -> Date {
        now.addingTimeInterval(-Retention.minuteLayer)
    }
}

/// An aggregation row for "seconds of app use in a given minute". Used by the
/// `roll_sec_to_min` job. Data class only — no behavior.
public struct MinuteAppUsage: Sendable, Equatable {
    public let minute: Date
    public let bundleId: String
    public let secondsUsed: Int

    public init(minute: Date, bundleId: String, secondsUsed: Int) {
        self.minute = minute
        self.bundleId = bundleId
        self.secondsUsed = secondsUsed
    }
}

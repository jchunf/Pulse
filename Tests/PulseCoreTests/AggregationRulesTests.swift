import Testing
import Foundation
@testable import PulseCore

@Suite("AggregationRules — time bucketing and retention cutoffs")
struct AggregationRulesTests {

    // MARK: - Second / minute / hour buckets

    @Test("second bucket floors sub-second component")
    func secondBucketFloors() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.789)
        let bucket = AggregationRules.secondBucket(for: instant)
        #expect(bucket.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("minute bucket aligns to 60s boundary")
    func minuteBucketAligns() {
        // 1_700_000_000 is a round minute boundary; +47s should floor back.
        let instant = Date(timeIntervalSince1970: 1_700_000_047)
        let bucket = AggregationRules.minuteBucket(for: instant)
        #expect(bucket.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("hour bucket aligns to 3600s boundary")
    func hourBucketAligns() {
        // 1_700_002_800 is an exact hour boundary (472223 * 3600).
        let hourBoundary: TimeInterval = 1_700_002_800
        let instant = Date(timeIntervalSince1970: hourBoundary + 47 * 60 + 13)
        let bucket = AggregationRules.hourBucket(for: instant)
        #expect(bucket.timeIntervalSince1970 == hourBoundary)
    }

    @Test("UTC day bucket aligns to 86400s boundary")
    func dayBucketAligns() {
        // 1_700_000_000 is Tue Nov 14 2023 22:13:20 UTC.
        // Day bucket = 1_699_920_000 (Tue Nov 14 00:00:00 UTC).
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = AggregationRules.utcDayBucket(for: instant)
        #expect(bucket.timeIntervalSince1970 == 1_699_920_000)
    }

    // MARK: - Idempotence

    @Test("bucketing a bucket is idempotent")
    func bucketIsIdempotent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 23 * 60 + 45)
        let once = AggregationRules.minuteBucket(for: now)
        let twice = AggregationRules.minuteBucket(for: once)
        #expect(once == twice)
    }

    // MARK: - Retention cutoffs

    @Test("raw retention is 14 days")
    func rawRetentionIs14Days() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = AggregationRules.rawCutoff(at: now)
        #expect(now.timeIntervalSince(cutoff) == 14 * 86_400)
    }

    @Test("second-layer retention is 30 days")
    func secondLayerRetentionIs30Days() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = AggregationRules.secondLayerCutoff(at: now)
        #expect(now.timeIntervalSince(cutoff) == 30 * 86_400)
    }

    @Test("minute-layer retention is 365 days")
    func minuteLayerRetentionIs365Days() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = AggregationRules.minuteLayerCutoff(at: now)
        #expect(now.timeIntervalSince(cutoff) == 365 * 86_400)
    }
}

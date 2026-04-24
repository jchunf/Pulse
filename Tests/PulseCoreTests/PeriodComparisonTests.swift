import Testing
import Foundation
@testable import PulseCore

@Suite("PeriodComparisonBuilder — even-split week-over-week (F-43)")
struct PeriodComparisonTests {

    private func day(_ offsetDays: Int, keys: Int = 0, clicks: Int = 0,
                     distance: Double = 0, scrolls: Int = 0) -> DailyTrendPoint {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return DailyTrendPoint(
            day: base.addingTimeInterval(Double(offsetDays) * 86_400),
            keyPresses: keys,
            mouseClicks: clicks,
            mouseDistanceMillimeters: distance,
            scrollTicks: scrolls
        )
    }

    @Test("returns nil for an empty or single-day trend")
    func notEnoughData() {
        #expect(PeriodComparisonBuilder.split(from: []) == nil)
        #expect(PeriodComparisonBuilder.split(from: [day(0)]) == nil)
    }

    @Test("splits 14 rows into 7-vs-7 and sums per metric")
    func weekOverWeekBasic() throws {
        // Days 0..6 = previous week, keyPresses all 100 → sum 700.
        // Days 7..13 = current week, keyPresses all 150 → sum 1050.
        let trend: [DailyTrendPoint] = (0..<14).map { i in
            day(i, keys: i < 7 ? 100 : 150, clicks: 10, distance: 50.0, scrolls: 5)
        }
        let comparison = try #require(PeriodComparisonBuilder.split(from: trend))
        #expect(comparison.currentPeriodDayCount == 7)
        #expect(comparison.previousPeriodDayCount == 7)

        let keystrokes = try #require(comparison[.keystrokes])
        #expect(keystrokes.previousValue == 700)
        #expect(keystrokes.currentValue == 1_050)
        #expect(abs((keystrokes.deltaFraction ?? 0) - 0.5) < 0.001)
    }

    @Test("odd-length trend drops the oldest row so halves stay equal")
    func oddLengthDropsOldest() throws {
        // 15 rows: odd. Builder should drop day 0 and compare 7 vs 7.
        let trend: [DailyTrendPoint] = (0..<15).map { i in
            // Put all the "signal" in day 0 — if the comparison count
            // is uneven the builder will silently pull day 0 into the
            // previous half and the test catches it.
            day(i, keys: i == 0 ? 999 : 0)
        }
        let comparison = try #require(PeriodComparisonBuilder.split(from: trend))
        #expect(comparison.currentPeriodDayCount == 7)
        #expect(comparison.previousPeriodDayCount == 7)
        let keystrokes = try #require(comparison[.keystrokes])
        // Day 0 dropped → both halves sum to zero.
        #expect(keystrokes.previousValue == 0)
        #expect(keystrokes.currentValue == 0)
    }

    @Test("deltaFraction is nil when previous period is zero")
    func zeroPreviousPeriod() throws {
        let trend: [DailyTrendPoint] = (0..<14).map { i in
            day(i, keys: i < 7 ? 0 : 100)
        }
        let comparison = try #require(PeriodComparisonBuilder.split(from: trend))
        let keystrokes = try #require(comparison[.keystrokes])
        #expect(keystrokes.previousValue == 0)
        #expect(keystrokes.currentValue == 700)
        #expect(keystrokes.deltaFraction == nil)
    }

    @Test("distance rollup sums real-valued millimeters")
    func distanceSum() throws {
        let trend: [DailyTrendPoint] = (0..<14).map { i in
            day(i, distance: i < 7 ? 100.5 : 200.25)
        }
        let comparison = try #require(PeriodComparisonBuilder.split(from: trend))
        let distance = try #require(comparison[.mouseDistanceMillimeters])
        #expect(abs(distance.previousValue - 703.5) < 0.001)
        #expect(abs(distance.currentValue - 1_401.75) < 0.001)
    }

    @Test("two-day trend reports 1-vs-1 bucket")
    func minimumTwoDayWindow() throws {
        let trend: [DailyTrendPoint] = [
            day(0, keys: 10),
            day(1, keys: 40)
        ]
        let comparison = try #require(PeriodComparisonBuilder.split(from: trend))
        #expect(comparison.previousPeriodDayCount == 1)
        #expect(comparison.currentPeriodDayCount == 1)
        let keystrokes = try #require(comparison[.keystrokes])
        #expect(keystrokes.previousValue == 10)
        #expect(keystrokes.currentValue == 40)
        #expect(abs((keystrokes.deltaFraction ?? 0) - 3.0) < 0.001)
    }
}

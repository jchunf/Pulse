import Foundation

/// Structured weekly snapshot rendered into the HTML report. Kept in
/// PulseCore so the rendering is a pure function of data + dates + a
/// locale-like caller contract, with no AppKit / SwiftUI dependency.
///
/// `days` is expected to be oldest → newest so the report reads left to
/// right. `weekStart` / `weekEnd` bracket the reported range (end is
/// exclusive).
public struct WeeklyReport: Sendable, Equatable {
    public let weekStart: Date
    public let weekEnd: Date
    public let days: [DailyTrendPoint]
    public let topApps: [AppUsageRow]
    public let totalDistanceMillimeters: Double
    public let totalKeystrokes: Int
    public let totalClicks: Int
    public let totalScrollTicks: Int
    public let totalIdleSeconds: Int
    public let landmark: LandmarkComparison

    public init(
        weekStart: Date,
        weekEnd: Date,
        days: [DailyTrendPoint],
        topApps: [AppUsageRow],
        totalDistanceMillimeters: Double,
        totalKeystrokes: Int,
        totalClicks: Int,
        totalScrollTicks: Int,
        totalIdleSeconds: Int,
        landmark: LandmarkComparison
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.days = days
        self.topApps = topApps
        self.totalDistanceMillimeters = totalDistanceMillimeters
        self.totalKeystrokes = totalKeystrokes
        self.totalClicks = totalClicks
        self.totalScrollTicks = totalScrollTicks
        self.totalIdleSeconds = totalIdleSeconds
        self.landmark = landmark
    }
}

/// Builds a `WeeklyReport` from the store. Small wrapper so callers
/// don't have to coordinate three different query helpers in the same
/// transaction.
public extension EventStore {

    func weeklyReport(
        endingAt: Date,
        days: Int = 7,
        calendar: Calendar = .current,
        library: LandmarkLibrary = .standard
    ) throws -> WeeklyReport {
        let endDay = calendar.startOfDay(for: endingAt)
        guard let weekStart = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
            throw WeeklyReportError.calendarBoundary
        }
        let weekEnd = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay

        let trend = try dailyTrend(endingAt: endDay, days: days, calendar: calendar)
        let topApps = try appUsageRanking(
            start: weekStart,
            end: weekEnd,
            capUntil: endingAt,
            limit: 10
        )
        let totalDistance = trend.reduce(0.0) { $0 + $1.mouseDistanceMillimeters }
        let totalKeys = trend.reduce(0) { $0 + $1.keyPresses }
        let totalClicks = trend.reduce(0) { $0 + $1.mouseClicks }
        let totalScrolls = trend.reduce(0) { $0 + $1.scrollTicks }
        let totalIdle = trend.reduce(0) { $0 + $1.idleSeconds }
        let landmark = library.bestMatch(forMeters: totalDistance / 1_000)

        return WeeklyReport(
            weekStart: weekStart,
            weekEnd: weekEnd,
            days: trend,
            topApps: topApps,
            totalDistanceMillimeters: totalDistance,
            totalKeystrokes: totalKeys,
            totalClicks: totalClicks,
            totalScrollTicks: totalScrolls,
            totalIdleSeconds: totalIdle,
            landmark: landmark
        )
    }
}

public enum WeeklyReportError: Error, Equatable {
    case calendarBoundary
}

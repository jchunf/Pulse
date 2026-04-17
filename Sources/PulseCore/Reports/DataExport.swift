import Foundation

/// Codable snapshot a user can hand to their own tooling — markdown
/// dailies, personal Obsidian vaults, spreadsheet scripts — without us
/// having to ship a CLI or API surface. Built by
/// `EventStore.buildExportBundle(days:)`.
///
/// Dates encode as ISO-8601 strings so downstream consumers don't have
/// to care about epochs. All keys use `snake_case`-ish camelCase the
/// Swift JSONEncoder defaults to; `outputFormatting: [.prettyPrinted,
/// .sortedKeys]` at the call site keeps the file diffable.
public struct ExportBundle: Codable, Sendable, Equatable {

    public struct DailyPoint: Codable, Sendable, Equatable {
        public let day: Date
        public let keyPresses: Int
        public let mouseClicks: Int
        public let mouseDistanceMillimeters: Double
        public let scrollTicks: Int
        public let idleSeconds: Int
    }

    public struct AppRow: Codable, Sendable, Equatable {
        public let bundleId: String
        public let secondsUsed: Int
    }

    public struct TodayTotals: Codable, Sendable, Equatable {
        public let keyPresses: Int
        public let mouseClicks: Int
        public let scrollTicks: Int
        public let mouseDistanceMillimeters: Double
        public let activeSeconds: Int
        public let idleSeconds: Int
    }

    public let schemaVersion: Int
    public let exportedAt: Date
    public let rangeStart: Date
    public let rangeEnd: Date
    public let today: TodayTotals
    public let dailyTrend: [DailyPoint]
    public let topApps: [AppRow]

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        rangeStart: Date,
        rangeEnd: Date,
        today: TodayTotals,
        dailyTrend: [DailyPoint],
        topApps: [AppRow]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.today = today
        self.dailyTrend = dailyTrend
        self.topApps = topApps
    }
}

public extension EventStore {

    /// Builds an `ExportBundle` covering `days` days of daily trend +
    /// top apps, plus today's live summary. Runs in a single read
    /// transaction on the GRDB queue.
    func buildExportBundle(
        endingAt: Date = Date(),
        days: Int = 30,
        calendar: Calendar = .current
    ) throws -> ExportBundle {
        precondition(days >= 1, "days must be ≥ 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let rangeStart = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEndExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            throw ExportBundleError.calendarBoundary
        }

        let trend = try dailyTrend(endingAt: endingAt, days: days, calendar: calendar)
        let todaySummary = try todaySummary(
            start: endDay,
            end: rangeEndExclusive,
            capUntil: endingAt
        )
        let apps = try appUsageRanking(
            start: rangeStart,
            end: rangeEndExclusive,
            capUntil: endingAt,
            limit: 20
        )

        return ExportBundle(
            schemaVersion: 1,
            exportedAt: endingAt,
            rangeStart: rangeStart,
            rangeEnd: rangeEndExclusive,
            today: ExportBundle.TodayTotals(
                keyPresses: todaySummary.totalKeyPresses,
                mouseClicks: todaySummary.totalMouseClicks,
                scrollTicks: todaySummary.totalScrollTicks,
                mouseDistanceMillimeters: todaySummary.totalMouseDistanceMillimeters,
                activeSeconds: todaySummary.totalActiveSeconds,
                idleSeconds: todaySummary.totalIdleSeconds
            ),
            dailyTrend: trend.map { point in
                ExportBundle.DailyPoint(
                    day: point.day,
                    keyPresses: point.keyPresses,
                    mouseClicks: point.mouseClicks,
                    mouseDistanceMillimeters: point.mouseDistanceMillimeters,
                    scrollTicks: point.scrollTicks,
                    idleSeconds: point.idleSeconds
                )
            },
            topApps: apps.map { row in
                ExportBundle.AppRow(
                    bundleId: row.bundleId,
                    secondsUsed: row.secondsUsed
                )
            }
        )
    }
}

public enum ExportBundleError: Error, Equatable {
    case calendarBoundary
}

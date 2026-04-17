#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore

/// Platform-side glue that (1) converts a raw `WeeklyReport` into a
/// fully-localized HTML document by wiring `PulseFormat.*` + the
/// `BundleDisplayNameCache` into the pure-Swift renderer in
/// `PulseCore.WeeklyReportHTMLRenderer`, and (2) writes it to disk under
/// `~/Library/Application Support/Pulse/reports/`.
enum WeeklyReportRenderer {

    private static let displayNameCache = BundleDisplayNameCache()

    static func renderLocalized(report: WeeklyReport) -> String {
        let startString = formatDate(report.weekStart, style: .long)
        let endInclusive = Calendar.current.date(byAdding: .day, value: -1, to: report.weekEnd) ?? report.weekEnd
        let endString = formatDate(endInclusive, style: .long)
        let title = String(localized: "weekly.report.title", bundle: .module)
        let subtitle = String.localizedStringWithFormat(
            String(localized: "weekly.report.subtitle", bundle: .module),
            startString,
            endString
        )
        let landmarkSentence = PulseFormat.landmarkComparisonSentence(for: report.landmark)

        let strings = WeeklyReportHTMLRenderer.Strings(
            title: title,
            subtitle: subtitle,
            distanceLabel:   String(localized: "Distance", bundle: .module),
            keystrokesLabel: String(localized: "Keystrokes", bundle: .module),
            clicksLabel:     String(localized: "Clicks", bundle: .module),
            scrollsLabel:    String(localized: "Scrolls", bundle: .module),
            idleLabel:       String(localized: "Idle time", bundle: .module),
            topAppsHeading:  String(localized: "Top apps", bundle: .module),
            dailyBreakdownHeading: String(localized: "weekly.report.dailyBreakdown", bundle: .module),
            dayHeader:       String(localized: "weekly.report.day", bundle: .module),
            appHeader:       String(localized: "weekly.report.app", bundle: .module),
            secondsHeader:   String(localized: "Active time", bundle: .module),
            landmarkSentence: landmarkSentence,
            generatedFooter: String.localizedStringWithFormat(
                String(localized: "weekly.report.generated", bundle: .module),
                formatDate(Date(), style: .medium)
            )
        )

        let formatters = WeeklyReportHTMLRenderer.Formatters(
            distance: { PulseFormat.distance(millimeters: $0) },
            integer: { PulseFormat.integer($0) },
            duration: { PulseFormat.duration(seconds: $0) },
            date: { formatDayShort($0) },
            appDisplayName: { Self.displayNameCache.name(for: $0) }
        )

        return WeeklyReportHTMLRenderer()
            .render(report: report, strings: strings, formatters: formatters)
    }

    static func writeToDisk(html: String, endingAt: Date) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "weekly-\(dayKey(endingAt)).html"
        let url = dir.appendingPathComponent(filename)
        try html.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date, style: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func formatDayShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
#endif

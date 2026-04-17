import Foundation

/// Renders a `WeeklyReport` into a self-contained HTML document. The
/// output is a single UTF-8 string with inlined CSS and no external
/// assets, so the file can be emailed, archived, or shared from disk
/// without pulling in a web of resources.
///
/// Styling mirrors the Dashboard's dark surface so the report doesn't
/// feel disconnected from the app. Rendered entries fall back to the
/// English `displayName` when a localized label isn't available — the
/// caller provides already-localized strings (date labels, anchor names)
/// rather than wiring `NSLocalizedString` inside PulseCore.
public struct WeeklyReportHTMLRenderer: Sendable {

    public struct Strings: Sendable {
        public let title: String
        public let subtitle: String
        public let distanceLabel: String
        public let keystrokesLabel: String
        public let clicksLabel: String
        public let scrollsLabel: String
        public let idleLabel: String
        public let topAppsHeading: String
        public let dailyBreakdownHeading: String
        public let dayHeader: String
        public let appHeader: String
        public let secondsHeader: String
        public let landmarkSentence: String
        public let generatedFooter: String

        public init(
            title: String,
            subtitle: String,
            distanceLabel: String,
            keystrokesLabel: String,
            clicksLabel: String,
            scrollsLabel: String,
            idleLabel: String,
            topAppsHeading: String,
            dailyBreakdownHeading: String,
            dayHeader: String,
            appHeader: String,
            secondsHeader: String,
            landmarkSentence: String,
            generatedFooter: String
        ) {
            self.title = title
            self.subtitle = subtitle
            self.distanceLabel = distanceLabel
            self.keystrokesLabel = keystrokesLabel
            self.clicksLabel = clicksLabel
            self.scrollsLabel = scrollsLabel
            self.idleLabel = idleLabel
            self.topAppsHeading = topAppsHeading
            self.dailyBreakdownHeading = dailyBreakdownHeading
            self.dayHeader = dayHeader
            self.appHeader = appHeader
            self.secondsHeader = secondsHeader
            self.landmarkSentence = landmarkSentence
            self.generatedFooter = generatedFooter
        }
    }

    /// Caller-supplied formatters so PulseCore stays locale-agnostic at
    /// rendering time. Each closure converts a primitive into a display
    /// string the renderer splats into HTML.
    public struct Formatters: Sendable {
        public let distance: @Sendable (Double) -> String     // mm
        public let integer: @Sendable (Int) -> String
        public let duration: @Sendable (Int) -> String        // seconds
        public let date: @Sendable (Date) -> String
        public let appDisplayName: @Sendable (String) -> String // bundleId → human

        public init(
            distance: @escaping @Sendable (Double) -> String,
            integer: @escaping @Sendable (Int) -> String,
            duration: @escaping @Sendable (Int) -> String,
            date: @escaping @Sendable (Date) -> String,
            appDisplayName: @escaping @Sendable (String) -> String
        ) {
            self.distance = distance
            self.integer = integer
            self.duration = duration
            self.date = date
            self.appDisplayName = appDisplayName
        }
    }

    public init() {}

    public func render(
        report: WeeklyReport,
        strings: Strings,
        formatters: Formatters
    ) -> String {
        let daysRows = report.days.map { point in
            """
            <tr>
              <td>\(escape(formatters.date(point.day)))</td>
              <td class="num">\(escape(formatters.integer(point.keyPresses)))</td>
              <td class="num">\(escape(formatters.integer(point.mouseClicks)))</td>
              <td class="num">\(escape(formatters.integer(point.scrollTicks)))</td>
              <td class="num">\(escape(formatters.distance(point.mouseDistanceMillimeters)))</td>
              <td class="num">\(escape(formatters.duration(point.idleSeconds)))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let appsRows = report.topApps.map { row in
            """
            <tr>
              <td>\(escape(formatters.appDisplayName(row.bundleId)))</td>
              <td class="num">\(escape(formatters.duration(row.secondsUsed)))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>\(escape(strings.title))</title>
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif;
              margin: 0; padding: 32px;
              background: #0f1115; color: #e7eaef;
            }
            h1 { font-size: 28px; margin: 0 0 6px; }
            h2 { font-size: 18px; margin: 24px 0 8px; color: #e7eaef; }
            p.subtitle { color: #9098a6; margin: 0 0 24px; }
            .hero {
              background: linear-gradient(135deg, rgba(255,127,80,0.18), rgba(255,127,80,0.04));
              border: 1px solid rgba(255,127,80,0.35);
              border-radius: 12px;
              padding: 20px; margin: 24px 0;
            }
            .hero .big { font-size: 44px; font-weight: 600; letter-spacing: -0.5px; }
            .hero .sub { color: #c0c7d2; margin-top: 8px; }
            .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin: 16px 0; }
            .kpi { background: #171b22; border-radius: 8px; padding: 14px; }
            .kpi .label { color: #9098a6; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
            .kpi .value { font-size: 22px; font-weight: 600; margin-top: 4px; font-variant-numeric: tabular-nums; }
            table { width: 100%; border-collapse: collapse; background: #171b22; border-radius: 8px; overflow: hidden; }
            th, td { padding: 10px 14px; border-bottom: 1px solid #222831; text-align: left; font-size: 14px; }
            th { background: #1d222a; color: #9098a6; font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
            td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
            footer { color: #626a78; font-size: 12px; margin-top: 32px; }
          </style>
        </head>
        <body>
          <h1>\(escape(strings.title))</h1>
          <p class="subtitle">\(escape(strings.subtitle))</p>

          <div class="hero">
            <div class="big">\(escape(formatters.distance(report.totalDistanceMillimeters)))</div>
            <div class="sub">\(escape(strings.landmarkSentence))</div>
          </div>

          <div class="kpis">
            <div class="kpi"><div class="label">\(escape(strings.keystrokesLabel))</div><div class="value">\(escape(formatters.integer(report.totalKeystrokes)))</div></div>
            <div class="kpi"><div class="label">\(escape(strings.clicksLabel))</div><div class="value">\(escape(formatters.integer(report.totalClicks)))</div></div>
            <div class="kpi"><div class="label">\(escape(strings.scrollsLabel))</div><div class="value">\(escape(formatters.integer(report.totalScrollTicks)))</div></div>
            <div class="kpi"><div class="label">\(escape(strings.idleLabel))</div><div class="value">\(escape(formatters.duration(report.totalIdleSeconds)))</div></div>
          </div>

          <h2>\(escape(strings.topAppsHeading))</h2>
          <table>
            <tr><th>\(escape(strings.appHeader))</th><th class="num">\(escape(strings.secondsHeader))</th></tr>
            \(appsRows)
          </table>

          <h2>\(escape(strings.dailyBreakdownHeading))</h2>
          <table>
            <tr>
              <th>\(escape(strings.dayHeader))</th>
              <th class="num">\(escape(strings.keystrokesLabel))</th>
              <th class="num">\(escape(strings.clicksLabel))</th>
              <th class="num">\(escape(strings.scrollsLabel))</th>
              <th class="num">\(escape(strings.distanceLabel))</th>
              <th class="num">\(escape(strings.idleLabel))</th>
            </tr>
            \(daysRows)
          </table>

          <footer>\(escape(strings.generatedFooter))</footer>
        </body>
        </html>
        """
    }

    private func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for char in s {
            switch char {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(char)
            }
        }
        return out
    }
}

#if canImport(AppKit)
import Foundation
import PulseCore

/// Locale-aware formatting helpers. Centralised so Chinese and English
/// builds render the same SwiftUI views without per-locale casing sprinkled
/// through `DashboardView` / `HealthMenuView` / `DiagnosticsCard`.
///
/// Every helper here routes through a `Foundation` formatter — `Measurement`,
/// `DateComponentsFormatter`, `RelativeDateTimeFormatter`, `Int.formatted` —
/// all of which honour `Locale.current` automatically. The only strings
/// authored inline (e.g. the fallback "just now") live in
/// `Localizable.xcstrings`.
enum PulseFormat {

    // MARK: - Relative time

    /// "5s ago" / "5 秒前". Falls back to the localised "just now" for
    /// anything under one second so the reader doesn't see "0s ago".
    static func ago(from instant: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(instant)
        if seconds < 1 {
            return String(localized: "just now", defaultValue: "just now", bundle: .pulse)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: instant, relativeTo: now)
    }

    // MARK: - Countdown ("in 15m", "15 分钟后")

    /// Formats a countdown from `now` until `target`. Uses
    /// `RelativeDateTimeFormatter` so the tense (in/ago) comes out right
    /// in every supported locale.
    static func countdown(from now: Date, to target: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: target, relativeTo: now)
    }

    // MARK: - Durations ("2h 15m" / "2小时 15分钟")

    static func duration(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        if seconds < 60 {
            formatter.allowedUnits = [.second]
        } else if seconds < 3_600 {
            formatter.allowedUnits = [.minute]
        } else {
            formatter.allowedUnits = [.hour, .minute]
        }
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    // MARK: - Distance ("3.20 km" / "3.20 公里")

    static func distance(millimeters: Double) -> String {
        let meters = millimeters / 1_000.0
        if meters < 0.1 {
            return Measurement(value: millimeters, unit: UnitLength.millimeters)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
        } else if meters < 1 {
            return Measurement(value: meters * 100, unit: UnitLength.centimeters)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
        } else if meters < 1_000 {
            return Measurement(value: meters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
        } else {
            return Measurement(value: meters / 1_000.0, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(2))))
        }
    }

    /// Compact meters-only variant used inside the milestone banner where
    /// we want to match the canonical landmark distance units.
    static func metersWhole(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    // MARK: - Integer / byte counts

    static func integer(_ value: Int) -> String { value.formatted(.number) }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Landmark name + comparison

    /// Display name for a landmark. Same xcstrings-compile workaround
    /// as the other dot-key sites: pivot on `Locale.prefersChinese`
    /// in Swift since the bundle lookup silently misses.
    static func localizedLandmarkName(for landmark: Landmark) -> String {
        let zh = Locale.prefersChinese
        switch landmark.key {
        case "step":        return zh ? "一步"        : "step"
        case "pool":        return zh ? "一个游泳池"  : "swimming pool length"
        case "track":       return zh ? "一圈田径跑道" : "athletics track lap"
        case "kilometer":   return zh ? "一公里"      : "kilometer"
        case "marathon":    return zh ? "一场马拉松"  : "marathon"
        case "beijing_gz":  return zh ? "北京 → 广州" : "Beijing → Guangzhou"
        case "pacific":     return zh ? "整个太平洋"  : "the Pacific"
        case "equator":     return zh ? "地球赤道"    : "Earth's equator"
        default:            return landmark.displayName
        }
    }

    // MARK: - Generic narrative anchors (A16)

    /// Display name for a `NarrativeAnchor`. Pivots on
    /// `Locale.prefersChinese` for the same reason as the landmark
    /// helper above.
    static func localizedAnchorName(for anchor: NarrativeAnchor) -> String {
        let zh = Locale.prefersChinese
        switch anchor.key {
        case "keystrokes.headline":       return zh ? "一条新闻标题"        : "news headline"
        case "keystrokes.sms":            return zh ? "一条短信"           : "text message"
        case "keystrokes.tweet":          return zh ? "一条推文"           : "tweet"
        case "keystrokes.shortStory":     return zh ? "一篇短篇小说"        : "short story"
        case "keystrokes.novella":        return zh ? "一部中篇"           : "novella"
        case "keystrokes.novel":          return zh ? "一部长篇"           : "novel"
        case "focus.pomodoro":            return zh ? "一个番茄钟"          : "pomodoro"
        case "focus.episode":             return zh ? "一集情景喜剧"        : "episode of a sitcom"
        case "focus.shortFilm":           return zh ? "一部短片"           : "short film"
        case "focus.feature":             return zh ? "一部长片"           : "feature film"
        case "focus.workday":             return zh ? "一整个工作日"        : "full work day"
        case "scroll.blogPost":           return zh ? "一篇博客"           : "blog post"
        case "scroll.tweetFeed":          return zh ? "一次推文流翻看"      : "tweet-feed session"
        case "scroll.magazine":           return zh ? "一期杂志"           : "magazine issue"
        case "scroll.novel":              return zh ? "一本小说"           : "novel"
        case "scroll.encyclopediaVolume": return zh ? "一卷百科全书"        : "encyclopedia volume"
        default:                          return anchor.displayName
        }
    }

    /// Dot-separated keys in `Localizable.xcstrings` aren't surviving
    /// the current xcstrings → .strings compile path (see the comment
    /// on `GoalPresetLocalizer` for the longer story). The comparison
    /// templates below therefore carry inline zh-Hans fallbacks pivoted
    /// on `Locale.prefersChinese`. These match the strings in the
    /// catalog verbatim so behaviour is identical once the pipeline
    /// is fixed.
    private static func comparisonTemplate(
        tiny: Bool = false,
        percent: Bool = false,
        aboutOne: Bool = false,
        multi: Bool = false
    ) -> String {
        let zh = Locale.prefersChinese
        if tiny     { return zh ? "仅为 %@ 的一小段"               : "a tiny fraction of %@" }
        if percent  { return zh ? "约为 %2$@ 的 %1$lld%%"          : "%lld%% of %@" }
        if aboutOne { return zh ? "约 1× %@"                       : "about 1× %@" }
        if multi    { return zh ? "约 %@× %@"                      : "≈ %@× %@" }
        return ""
    }

    /// One-line dramatic framing for any `NarrativeComparison`.
    static func narrativeSentence(for comparison: NarrativeComparison) -> String {
        let name = localizedAnchorName(for: comparison.anchor)
        let m = comparison.multiplier
        if m < 1 {
            let pct = Int((m * 100).rounded())
            return String.localizedStringWithFormat(comparisonTemplate(percent: true), pct, name)
        } else if m < 2 {
            return String.localizedStringWithFormat(comparisonTemplate(aboutOne: true), name)
        } else {
            let rounded = (m * 10).rounded() / 10
            let multiplierString = rounded.formatted(.number.precision(.fractionLength(1)))
            return String.localizedStringWithFormat(comparisonTemplate(multi: true), multiplierString, name)
        }
    }

    /// Dramatic-comparison line for the Mileage card.
    static func landmarkComparisonSentence(for comparison: LandmarkComparison) -> String {
        let name = localizedLandmarkName(for: comparison.landmark)
        let m = comparison.multiplier
        if m < 0.01 {
            return String.localizedStringWithFormat(comparisonTemplate(tiny: true), name)
        } else if m < 1 {
            let pct = Int((m * 100).rounded())
            return String.localizedStringWithFormat(comparisonTemplate(percent: true), pct, name)
        } else if m < 2 {
            return String.localizedStringWithFormat(comparisonTemplate(aboutOne: true), name)
        } else {
            let rounded = (m * 10).rounded() / 10
            let multiplierString = rounded.formatted(.number.precision(.fractionLength(1)))
            return String.localizedStringWithFormat(comparisonTemplate(multi: true), multiplierString, name)
        }
    }
}
#endif

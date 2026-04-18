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
            return String(localized: "just now", defaultValue: "just now", bundle: .module)
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

    /// Looks up the translated display name for a landmark via its stable
    /// key (e.g. `landmark.marathon.name`). Uses `NSLocalizedString` (not
    /// `String(localized:)`) because the key is a runtime-composed string
    /// and `defaultValue` only accepts `StaticString` keys. Falls back to
    /// the English `Landmark.displayName` when the catalog has no entry.
    static func localizedLandmarkName(for landmark: Landmark) -> String {
        NSLocalizedString(
            "landmark.\(landmark.key).name",
            bundle: .module,
            value: landmark.displayName,
            comment: "Localised landmark display name for the mileage comparison"
        )
    }

    // MARK: - Generic narrative anchors (A16)

    /// Localised name for a `NarrativeAnchor`. Looks up the catalog key
    /// (`keystrokes.tweet`, `focus.episode`, …); falls back to the English
    /// `displayName` when the translation is missing so we never render
    /// an empty line.
    static func localizedAnchorName(for anchor: NarrativeAnchor) -> String {
        NSLocalizedString(
            anchor.key,
            bundle: .module,
            value: anchor.displayName,
            comment: "Localised NarrativeEngine anchor name"
        )
    }

    /// One-line dramatic framing for any `NarrativeComparison`. Ladder
    /// mirrors the mileage landmark branches:
    /// - `m < 1`   → "X% of a %@"  (anchor bigger than observation)
    /// - `m < 2`   → "about 1× a %@"
    /// - else      → "≈ M× a %@"   with one decimal
    static func narrativeSentence(for comparison: NarrativeComparison) -> String {
        let name = localizedAnchorName(for: comparison.anchor)
        let m = comparison.multiplier
        if m < 1 {
            let pct = Int((m * 100).rounded())
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.percent", bundle: .module),
                pct,
                name
            )
        } else if m < 2 {
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.aboutOne", bundle: .module),
                name
            )
        } else {
            let rounded = (m * 10).rounded() / 10
            let multiplierString = rounded.formatted(.number.precision(.fractionLength(1)))
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.multi", bundle: .module),
                multiplierString,
                name
            )
        }
    }

    /// Dramatic-comparison line for the Mileage card. Mirrors the
    /// `LandmarkLibrary.formatMultiplier` branches but composed from
    /// localised templates in `Localizable.xcstrings`.
    static func landmarkComparisonSentence(for comparison: LandmarkComparison) -> String {
        let name = localizedLandmarkName(for: comparison.landmark)
        let m = comparison.multiplier
        if m < 0.01 {
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.tiny", bundle: .module),
                name
            )
        } else if m < 1 {
            let pct = Int((m * 100).rounded())
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.percent", bundle: .module),
                pct,
                name
            )
        } else if m < 2 {
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.aboutOne", bundle: .module),
                name
            )
        } else {
            let rounded = (m * 10).rounded() / 10
            let multiplierString = rounded.formatted(.number.precision(.fractionLength(1)))
            return String.localizedStringWithFormat(
                String(localized: "mileage.comparison.multi", bundle: .module),
                multiplierString,
                name
            )
        }
    }
}
#endif

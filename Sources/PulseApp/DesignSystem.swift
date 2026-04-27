import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// "Vital Pulse" design system — the warm, Apple-Fitness-adjacent visual
/// language introduced in A26b. Four constants that future `View` code can
/// lean on instead of hand-rolling `Color.orange` / `LinearGradient` /
/// `.font(.title2.bold())` at every call site.
///
/// Thematic hook: the app is named after a *heartbeat* (脉搏). The palette
/// leans toward skin / warmth / temperature; the typography uses SF Pro
/// Rounded for numeric hero display (Apple Fitness' move); a `.pulse()`
/// view modifier provides the gentle scale animation that lets the
/// interface actually feel like it breathes.
///
/// This file is foundation only — no existing view changes. Subsequent
/// slices (A26c / A26d / A26e) apply it outward.
public enum PulseDesign {

    // MARK: - Palette

    /// Principal accent — warm coral. Used for:
    ///  • Hero numerals (today's distance, longest focus duration)
    ///  • Primary CTAs (`.borderedProminent` tint)
    ///  • Heatmap intensity gradient
    ///  • Menu-bar icon tint while actively collecting
    /// Replaces every prior use of `Color.accentColor` that wanted
    /// "the app's signature colour" rather than "the user's system tint".
    public static let coral = Color.dynamic(
        light: 0xF56565,
        dark:  0xFF7A7A   // slightly lighter in dark mode for contrast
    )

    /// Secondary — sage green. Used for:
    ///  • Achieved landmarks ("✓" prefix + milestone-history entries)
    ///  • "Steady flow" / "Deep worker" posture labels
    ///  • Onboarding "granted" permission chip
    /// Replaces every prior `Color.green` in UI paths.
    public static let sage = Color.dynamic(
        light: 0x86C3A0,
        dark:  0x9AD1B3
    )

    /// Tertiary — amber. Used for:
    ///  • Warning banners (missing permissions, anomaly chip)
    ///  • "Short-form" / "Checker" posture labels
    /// Replaces every prior `Color.orange` / `Color.yellow` in UI paths.
    public static let amber = Color.dynamic(
        light: 0xE5A14A,
        dark:  0xEBB06A
    )

    /// Off-white / deep-indigo dashboard background. Avoids pure white +
    /// pure black, both of which read as "stern tool". The subtle warm
    /// cast keeps the app feeling skin-adjacent even on a calibrated
    /// display.
    public static let surface = Color.dynamic(
        light: 0xFAFAF7,
        dark:  0x1C1B21
    )

    /// Warm neutral tint for card fills and subtle separators. Slight
    /// positive hue offset so it reads differently from the native macOS
    /// `.quaternary` gray. `opacity` is what varies — baseline is 0.05
    /// on light, 0.08 on dark.
    public static func warmGray(_ opacity: Double = 0.05) -> Color {
        Color.dynamic(
            light: 0x8B7E6F,
            dark:  0xC9BFAD
        ).opacity(opacity)
    }

    /// "Display surface" — the Strava-personal-heatmap dark plate used
    /// behind the F-04 mouse-trail bitmap so quiet regions fade into
    /// dark and peaks lift through coral toward a near-white halo.
    /// Roughly the same colour in light and dark mode (a near-black
    /// with a faint warm bias) because the bitmap is the figure here
    /// and the plate is intentionally muted; matching it to the
    /// surrounding card surface would defeat the "this is a screen"
    /// silhouette the visualisation depends on.
    public static let displaySurface = Color.dynamic(
        light: 0x1A1316,
        dark:  0x0E0B0E
    )

    // MARK: - Semantic roles

    /// Positive delta (up-trend on a metric). Sage, not green. Used by
    /// `DeltaChip` after A26c.
    public static let deltaPositive = sage

    /// Negative delta (down-trend on a metric). Amber, not orange. Used
    /// by `DeltaChip` after A26c.
    public static let deltaNegative = amber

    /// Silent-failure / permission-missing warning. Amber.
    public static let warning = amber

    /// Hard error / anomaly / collection paused due to system problem.
    /// Kept as `.red` because the menu-bar anomaly dot has been that
    /// colour since A19b and users have already learned that signal.
    public static let critical = Color.red

    // MARK: - Typography

    /// Hero numerals — Apple-Fitness-style large rounded. Used for the
    /// single largest number on the Dashboard (today's mileage) plus any
    /// future "one big number" moments (Deep focus duration, lifetime
    /// mileage).
    ///
    /// `.rounded` design is deliberate: rounded digits read as *friendly*
    /// and soften the "serious analytics tool" vibe. `.semibold` (not
    /// `.bold`) keeps weight disciplined.
    public static let heroFont: Font = .system(
        size: 64, weight: .semibold, design: .rounded
    )

    /// Secondary hero — used when two large numbers share a row (e.g.
    /// lifetime + today).
    public static let heroSecondaryFont: Font = .system(
        size: 40, weight: .semibold, design: .rounded
    )

    /// Card title — rounded, medium weight, title3 scale. Every card
    /// header after A26c uses this in place of `.headline` / `.title2`.
    public static let cardTitleFont: Font = .system(
        .title3, design: .rounded, weight: .semibold
    )

    /// Data value inside a summary card — monospaced rounded digits,
    /// regular weight. Replaces the current `.title2.bold.monospacedDigit`.
    public static let metricFont: Font = .system(
        size: 30, weight: .medium, design: .rounded
    ).monospacedDigit()

    /// Small label — caption with letter-spacing (applied via
    /// `.tracking` at the call site), lowercase; replaces `textCase(.uppercase)`
    /// caption shouting that dominates the current design.
    public static let labelFont: Font = .system(
        .caption, design: .rounded, weight: .regular
    )

    // MARK: - Geometry

    /// Standard card corner radius. Matches Apple's own card-based apps
    /// (Fitness, Health, Weather) at their default size.
    public static let cardCornerRadius: CGFloat = 16

    /// Hero card gets a touch more radius to separate it from the rest.
    public static let heroCornerRadius: CGFloat = 18

    /// Card internal padding. 24pt across every card gives the app a
    /// consistent "breathing" rhythm.
    public static let cardPadding: CGFloat = 24

    /// Vertical spacing between stacked cards on the Dashboard.
    public static let cardSpacing: CGFloat = 28
}

// MARK: - Color hex helper

extension Color {
    /// Colour literal from `0xRRGGBB`. macOS-native — uses `NSColor` so
    /// the resulting `Color` goes through AppKit's colour management
    /// (sRGB calibrated) rather than SwiftUI's display-P3 default.
    fileprivate static func hex(_ rgb: UInt32) -> Color {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Colour that adapts to light / dark mode. Without an asset catalog
    /// this is the cleanest way to get system-tracked colour in a SPM
    /// project; the dynamic provider queries the current effective
    /// appearance every time the color is rendered.
    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit)
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(
                from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]
            ) == .darkAqua || appearance.bestMatch(
                from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]
            ) == .vibrantDark
            let rgb = isDark ? dark : light
            let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let g = CGFloat((rgb >>  8) & 0xFF) / 255.0
            let b = CGFloat( rgb        & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        return Color(nsColor: nsColor)
        #else
        return .hex(light)
        #endif
    }
}

// MARK: - Card style modifier

extension View {
    /// Applies the "Vital Pulse" hero-card treatment: a very soft coral
    /// tint background, large corner radius, generous padding, a subtle
    /// shadow. Reserved for the single most-important card on the
    /// Dashboard (mileage hero after A26c).
    public func pulseHeroCard() -> some View {
        self
            .padding(PulseDesign.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PulseDesign.heroCornerRadius)
                    .fill(PulseDesign.coral.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseDesign.heroCornerRadius)
                    .strokeBorder(PulseDesign.coral.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 20, x: 0, y: 6)
    }

    /// Applies the "Vital Pulse" featured-card treatment: warm-gray
    /// subtle tint, no stroke, no shadow. Used for the second tier of
    /// cards (Deep Focus, Usage Posture, Milestone History) — still a
    /// distinct container but quieter than the hero.
    public func pulseFeaturedCard() -> some View {
        self
            .padding(PulseDesign.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PulseDesign.cardCornerRadius)
                    .fill(PulseDesign.warmGray(0.05))
            )
    }

    /// Plain-card treatment: padding + spacing but no visible background
    /// at all. Used for the six summary metric cards after A26c — they
    /// separate through whitespace + typography, not through chrome.
    public func pulsePlainCard() -> some View {
        self
            .padding(PulseDesign.cardPadding * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Heartbeat animation modifier

/// `View` modifier that applies a gentle looping scale pulse to echo the
/// app's name. Uses `TimelineView` so the animation runs on every render
/// rather than being tied to any specific `@State` change — this means
/// the pulse starts automatically when the view appears and stops when
/// it disappears, with no ownership to plumb through.
///
/// Intended usage:
///   • Menu-bar icon: `Image(...).pulseHeartbeat(active: !isPaused)`
///   • Hero card background: a concentric `Circle()` with
///     `.pulseHeartbeat(active: true, amplitude: .hero)`
public struct PulseHeartbeatModifier: ViewModifier {

    public enum Amplitude {
        /// Very subtle (+4%). For menu-bar icon.
        case menuBar
        /// Moderate (+8%). For hero-card background accents.
        case hero
        /// Burst (+14%). For milestone-achieved one-shot celebrations.
        case burst

        fileprivate var scaleDelta: Double {
            switch self {
            case .menuBar: return 0.04
            case .hero:    return 0.08
            case .burst:   return 0.14
            }
        }

        fileprivate var period: Double {
            switch self {
            case .menuBar: return 2.4
            case .hero:    return 3.2
            case .burst:   return 1.0
            }
        }
    }

    let active: Bool
    let amplitude: Amplitude

    @State private var expanded: Bool = false

    public func body(content: Content) -> some View {
        content
            .scaleEffect(expanded ? 1 + amplitude.scaleDelta : 1)
            .animation(
                active
                    ? .easeInOut(duration: amplitude.period / 2).repeatForever(autoreverses: true)
                    : .default,
                value: expanded
            )
            .onAppear { if active { expanded = true } }
            .onChange(of: active) { _, nowActive in
                expanded = nowActive
            }
    }
}

extension View {
    /// Attach a gentle scale pulse to a view — makes it "breathe" at the
    /// chosen amplitude. Set `active: false` to stop the animation (e.g.
    /// when the collector is paused).
    public func pulseHeartbeat(
        active: Bool = true,
        amplitude: PulseHeartbeatModifier.Amplitude = .menuBar
    ) -> some View {
        modifier(PulseHeartbeatModifier(active: active, amplitude: amplitude))
    }
}

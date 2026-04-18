import Foundation
import CoreGraphics

/// Converts pixel-space distances into physical distance (millimeters, meters,
/// kilometers). This is what powers the pointer odometer (F-07) — the flagship
/// "dramatic" feature that turns boring mouse data into a running story.
///
/// Design notes:
/// - We use the display's physical DPI at the time the movement was observed.
///   Conversion is linear; once normalized, accumulating distance is additive
///   across displays.
/// - Formulas use 1 inch = 25.4 mm exactly.
public struct MileageConverter: Sendable {
    public init() {}

    /// Converts a pixel distance on a known display into millimeters.
    public func millimeters(pixels: Double, on display: DisplayInfo) -> Double {
        pixels * display.millimetersPerPixel
    }

    /// Convert millimeters to meters.
    public func meters(fromMillimeters mm: Double) -> Double { mm / 1_000.0 }

    /// Convert millimeters to kilometers.
    public func kilometers(fromMillimeters mm: Double) -> Double { mm / 1_000_000.0 }

    /// Computes Euclidean distance between two normalized points that share a
    /// display, and converts the result to millimeters. The two points MUST
    /// be on the same display — callers are responsible for splitting
    /// cross-display segments.
    ///
    /// A26: The math now uses **logical points**, not native pixels. Pre-A26
    /// the code took point-space deltas, multiplied by `widthPx` (native
    /// pixels), then multiplied by `mm/pixel` — which quietly undercounted
    /// distance by the backing-scale factor on every Retina Mac. Post-A26,
    /// we scale by `widthPoints` + use `millimetersPerPoint`, which gives
    /// physically correct mm on both Retina and non-Retina.
    public func millimeters(between a: NormalizedPoint, and b: NormalizedPoint, on display: DisplayInfo) -> Double {
        precondition(a.displayId == b.displayId, "distance between points on different displays is undefined")
        let dx = (a.x - b.x) * Double(display.widthPoints)
        let dy = (a.y - b.y) * Double(display.heightPoints)
        let points = (dx * dx + dy * dy).squareRoot()
        return points * display.millimetersPerPoint
    }
}

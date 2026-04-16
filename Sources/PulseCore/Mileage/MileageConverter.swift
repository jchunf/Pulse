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
    public func millimeters(between a: NormalizedPoint, and b: NormalizedPoint, on display: DisplayInfo) -> Double {
        precondition(a.displayId == b.displayId, "distance between points on different displays is undefined")
        let dx = (a.x - b.x) * Double(display.widthPx)
        let dy = (a.y - b.y) * Double(display.heightPx)
        let pixels = (dx * dx + dy * dy).squareRoot()
        return millimeters(pixels: pixels, on: display)
    }
}

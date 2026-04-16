import Foundation

/// Abstract view of all connected displays. `LiveDisplayRegistry` in
/// `PulsePlatform` uses `CGGetOnlineDisplayList` + reconfiguration
/// callbacks; tests use a static `FakeDisplayRegistry`.
public protocol DisplayRegistry: Sendable {
    /// All currently connected displays.
    var displays: [DisplayInfo] { get }

    /// Locate the display that contains the given global pixel coordinates.
    /// Returns `nil` if the point is outside every display (e.g., stale
    /// coordinates after a disconnect).
    func display(containing globalPoint: CGPoint) -> DisplayInfo?
}

import CoreGraphics

/// Platform-independent normalization of a global pixel coordinate into
/// `[0, 1]` space relative to a single display. This is the exact algorithm
/// stored events go through — isolating it here means we can unit test every
/// edge case (multi-display layouts, retina scaling, point-on-boundary)
/// without touching the window server.
public struct CoordNormalizer: Sendable {
    public init() {}

    /// Normalize a pixel point inside the display's local coordinate space
    /// (where 0,0 is the display's top-left). Clamps to `[0, 1]` so
    /// off-by-one boundary events don't produce out-of-range data.
    public func normalize(localPoint: CGPoint, on display: DisplayInfo) -> NormalizedPoint {
        let width = max(Double(display.widthPx), 1.0)
        let height = max(Double(display.heightPx), 1.0)
        let x = clamp01(Double(localPoint.x) / width)
        let y = clamp01(Double(localPoint.y) / height)
        return NormalizedPoint(displayId: display.id, x: x, y: y)
    }

    /// Inverse of `normalize`. Useful when rendering historical heatmaps
    /// against a known display snapshot.
    public func denormalize(_ point: NormalizedPoint, on display: DisplayInfo) -> CGPoint {
        CGPoint(
            x: point.x * Double(display.widthPx),
            y: point.y * Double(display.heightPx)
        )
    }

    private func clamp01(_ value: Double) -> Double {
        if value.isNaN { return 0.0 }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }
}

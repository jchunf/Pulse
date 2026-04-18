import Foundation

/// A single display's physical attributes at a given moment.
/// Stored in `display_snapshots` so historical normalized coordinates can be
/// rendered back to the correct pixel space when screens are later resized
/// or disconnected. See `docs/04-architecture.md#4.1`.
public struct DisplayInfo: Sendable, Equatable, Hashable {
    public let id: UInt32
    /// Native (backing-store) pixel width. On a Retina display this is
    /// `widthPoints * scaleFactor`.
    public let widthPx: Int
    /// Native (backing-store) pixel height.
    public let heightPx: Int
    /// Logical point width — what AppKit / `CGDisplayBounds` / `CGEvent.location`
    /// all use. On a 2x Retina display this is half of `widthPx`.
    /// Defaults to `widthPx` for backwards compatibility with test
    /// fixtures that pre-date A26 (those are non-Retina where points
    /// and pixels coincide).
    public let widthPoints: Int
    /// Logical point height — see `widthPoints`.
    public let heightPoints: Int
    /// Native pixels per inch derived from EDID. Cheap external monitors
    /// and HDMI-bridged displays sometimes report bogus physical sizes;
    /// `MileageCalibration` lets the user override the resulting
    /// `millimetersPerPoint` per display at runtime.
    public let dpi: Double
    public let isPrimary: Bool

    public init(
        id: UInt32,
        widthPx: Int,
        heightPx: Int,
        widthPoints: Int? = nil,
        heightPoints: Int? = nil,
        dpi: Double,
        isPrimary: Bool
    ) {
        self.id = id
        self.widthPx = widthPx
        self.heightPx = heightPx
        // Default points to native pixels — correct for non-Retina (1x)
        // displays, which is what every pre-A26 call site assumes. The
        // live registry overrides these with real `CGDisplayBounds`
        // point dimensions so Retina displays compute distance right.
        self.widthPoints = widthPoints ?? widthPx
        self.heightPoints = heightPoints ?? heightPx
        self.dpi = dpi
        self.isPrimary = isPrimary
    }

    /// Millimeters per native pixel along one axis (1 inch = 25.4 mm).
    /// Kept for any external consumer that genuinely wants the pixel
    /// figure; `MileageConverter` uses `millimetersPerPoint` instead.
    public var millimetersPerPixel: Double {
        25.4 / dpi
    }

    /// Millimeters per logical point — the unit in which `CGEvent.location`
    /// deltas actually arrive, and therefore the right multiplier for
    /// turning cursor motion into physical distance.
    ///
    /// On non-Retina displays this equals `millimetersPerPixel`; on a
    /// 2x Retina display it is ≈ twice that. Pre-A26, the pointer
    /// odometer multiplied point-space deltas by `millimetersPerPixel`
    /// — which under-reported distance by the backing-scale factor on
    /// every Retina Mac shipped since ~2012.
    public var millimetersPerPoint: Double {
        // mmPerPoint = mmPerNativePixel × (nativePixels per point)
        let scale = Double(widthPx) / Double(max(widthPoints, 1))
        return millimetersPerPixel * scale
    }
}

/// A normalized point in `[0, 1] × [0, 1]` tied to a specific display at a
/// specific instant. Storing this (rather than raw pixels) is the decision
/// recorded in `docs/04-architecture.md#4.1`: it survives resolution changes
/// and external-monitor reconfiguration without losing fidelity.
public struct NormalizedPoint: Sendable, Equatable, Hashable {
    public let displayId: UInt32
    public let x: Double // [0, 1]
    public let y: Double // [0, 1]

    public init(displayId: UInt32, x: Double, y: Double) {
        self.displayId = displayId
        self.x = x
        self.y = y
    }
}

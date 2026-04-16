import Foundation

/// A single display's physical attributes at a given moment.
/// Stored in `display_snapshots` so historical normalized coordinates can be
/// rendered back to the correct pixel space when screens are later resized
/// or disconnected. See `docs/04-architecture.md#4.1`.
public struct DisplayInfo: Sendable, Equatable, Hashable {
    public let id: UInt32
    public let widthPx: Int
    public let heightPx: Int
    public let dpi: Double
    public let isPrimary: Bool

    public init(id: UInt32, widthPx: Int, heightPx: Int, dpi: Double, isPrimary: Bool) {
        self.id = id
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.dpi = dpi
        self.isPrimary = isPrimary
    }

    /// Millimeters per pixel along one axis (1 inch = 25.4 mm).
    /// Used by `MileageConverter` to turn pixel distance into physical
    /// distance for the pointer odometer (F-07).
    public var millimetersPerPixel: Double {
        25.4 / dpi
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

import Foundation
import CoreGraphics
import PulseCore

/// A `DisplayRegistry` backed by an in-memory array. Layout is "classic":
/// each display is placed to the right of the previous one along the x-axis.
/// Good enough for deterministic tests; the live implementation uses the
/// real global coordinate space that may include displays at negative
/// coordinates, stacked vertically, etc.
public final class FakeDisplayRegistry: DisplayRegistry, @unchecked Sendable {

    private let lock = NSLock()
    private var ordered: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.ordered = displays
    }

    public var displays: [DisplayInfo] {
        lock.lock(); defer { lock.unlock() }
        return ordered
    }

    public func display(containing globalPoint: CGPoint) -> DisplayInfo? {
        lock.lock(); defer { lock.unlock() }
        var originX: CGFloat = 0
        for display in ordered {
            let width = CGFloat(display.widthPx)
            let height = CGFloat(display.heightPx)
            let frame = CGRect(x: originX, y: 0, width: width, height: height)
            if frame.contains(globalPoint) {
                return display
            }
            originX += width
        }
        return nil
    }

    public func replace(with displays: [DisplayInfo]) {
        lock.lock(); defer { lock.unlock() }
        self.ordered = displays
    }
}

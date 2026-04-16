#if canImport(AppKit)
import AppKit
import CoreGraphics
import PulseCore

/// Live `DisplayRegistry` backed by Core Graphics. Caches the display list
/// and refreshes on reconfiguration callbacks from `CGDisplayRegister`.
///
/// DPI is computed from each display's physical size in millimeters and its
/// pixel resolution. For displays that do not report a physical size (rare
/// but possible with projectors), a conservative fallback of 96 DPI is used.
public final class LiveDisplayRegistry: DisplayRegistry, @unchecked Sendable {

    private let lock = NSLock()
    private var cached: [DisplayInfo] = []
    private var observing: Bool = false

    public init() {
        refresh()
        registerForReconfiguration()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    public var displays: [DisplayInfo] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func display(containing globalPoint: CGPoint) -> DisplayInfo? {
        lock.lock(); defer { lock.unlock() }
        for display in cached {
            if let bounds = displayBounds(id: display.id), bounds.contains(globalPoint) {
                return display
            }
        }
        return nil
    }

    // MARK: - Private

    private func registerForReconfiguration() {
        guard !observing else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, ptr)
        observing = true
    }

    private func refresh() {
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let error = CGGetOnlineDisplayList(UInt32(online.count), &online, &count)
        guard error == .success else {
            lock.lock()
            cached = []
            lock.unlock()
            return
        }
        let ids = Array(online.prefix(Int(count)))
        let mainId = CGMainDisplayID()
        var next: [DisplayInfo] = []
        for id in ids {
            let widthPx = Int(CGDisplayPixelsWide(id))
            let heightPx = Int(CGDisplayPixelsHigh(id))
            let mmSize = CGDisplayScreenSize(id)
            let dpi: Double
            if mmSize.width > 0 {
                dpi = Double(widthPx) / (Double(mmSize.width) / 25.4)
            } else {
                dpi = 96
            }
            next.append(
                DisplayInfo(
                    id: UInt32(id),
                    widthPx: widthPx,
                    heightPx: heightPx,
                    dpi: dpi,
                    isPrimary: id == mainId
                )
            )
        }
        lock.lock()
        cached = next
        lock.unlock()
    }

    private func displayBounds(id: UInt32) -> CGRect? {
        let rect = CGDisplayBounds(CGDirectDisplayID(id))
        return rect.isNull ? nil : rect
    }

    fileprivate func handleReconfiguration() {
        refresh()
    }
}

/// Free function required by Core Graphics callback convention.
private func reconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let registry = Unmanaged<LiveDisplayRegistry>.fromOpaque(userInfo).takeUnretainedValue()
    registry.handleReconfiguration()
}
#endif

#if canImport(AppKit)
import AppKit
import CoreGraphics
import PulseCore

/// Live `EventSource` backed by `CGEventTap`. B1 intentionally ships a
/// conservative scaffold: it proves the wiring (permission check, tap
/// creation, runloop registration, handler dispatch) and emits `keyPress`
/// events with `nil` keycodes and raw mouse move events translated through
/// a `DisplayRegistry` + `CoordNormalizer`.
///
/// Out of scope for B1 and deferred to B2:
/// - Adaptive sampling (drop to 1 Hz when idle, see docs/04-architecture.md#4.2)
/// - Keycode distribution capture (gated by user opt-in per Q-06)
/// - Double-click detection (currently always `false`)
/// - Scroll deltas (currently 0)
///
/// The scaffold is exercised only on macOS and is guarded behind
/// `canImport(AppKit)` so `swift build` on Linux for CI smoke still compiles
/// the package without it.
public final class CGEventTapSource: EventSource, @unchecked Sendable {

    private let permissions: PermissionService
    private let displayRegistry: DisplayRegistry
    private let normalizer: CoordNormalizer
    private let clock: Clock

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (DomainEvent) -> Void)?

    public init(
        permissions: PermissionService,
        displayRegistry: DisplayRegistry,
        clock: Clock = SystemClock(),
        normalizer: CoordNormalizer = CoordNormalizer()
    ) {
        self.permissions = permissions
        self.displayRegistry = displayRegistry
        self.clock = clock
        self.normalizer = normalizer
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        guard tap == nil else { throw EventSourceError.alreadyRunning }

        if permissions.status(of: .inputMonitoring) != .granted {
            throw EventSourceError.permissionDenied(.inputMonitoring)
        }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        self.handler = handler
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, info in
                guard let info else { return Unmanaged.passUnretained(cgEvent) }
                let source = Unmanaged<CGEventTapSource>.fromOpaque(info).takeUnretainedValue()
                source.handle(type: type, event: cgEvent)
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: opaqueSelf
        ) else {
            self.handler = nil
            throw EventSourceError.platformFailure("CGEvent.tapCreate returned nil")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let tap = self.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = self.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
        self.handler = nil
    }

    deinit {
        // Belt and suspenders: guarantee the tap is torn down even if the
        // caller forgot `stop()`. Tapping into `self` after deinit is UB,
        // so callers should stop() explicitly, but this keeps us safe in
        // common-case cleanup paths.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let handlerCopy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        handlerCopy = self.handler
        lock.unlock()
        guard let handler = handlerCopy else { return }

        let now = clock.now
        switch type {
        case .mouseMoved:
            if let point = normalizePointer(event) {
                handler(.mouseMove(point, at: now))
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let point = normalizePointer(event) {
                let button = buttonKind(type)
                handler(.mouseClick(button, point: point, doubleClick: false, at: now))
            }
        case .scrollWheel:
            handler(.mouseScroll(delta: 0, horizontal: false, at: now))
        case .keyDown:
            // B1 emits a keycode-less press. Keycode capture is opt-in and
            // wired in B2 (see Q-06 and docs/05-privacy.md).
            handler(.keyPress(keyCode: nil, at: now))
        default:
            break
        }
    }

    private func normalizePointer(_ event: CGEvent) -> NormalizedPoint? {
        let location = event.location
        guard let display = displayRegistry.display(containing: location) else {
            return nil
        }
        // Translate global coordinates to display-local by subtracting the
        // display's origin. `display(containing:)` already identified the
        // right display; use CGDisplayBounds for origin.
        let bounds = CGDisplayBounds(CGDirectDisplayID(display.id))
        let local = CGPoint(x: location.x - bounds.origin.x, y: location.y - bounds.origin.y)
        return normalizer.normalize(localPoint: local, on: display)
    }

    private func buttonKind(_ type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown: return .left
        case .rightMouseDown: return .right
        case .otherMouseDown: return .middle
        default: return .other
        }
    }
}
#endif

#if canImport(AppKit)
import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import PulseCore

/// Observes lid (clamshell) state and the active power source via IOKit and
/// emits the corresponding `DomainEvent`s. Like `SystemEventEmitter`, the
/// observer hands events to a caller-supplied closure rather than touching
/// the runtime directly, so the same pause / sampling / idle gating that
/// applies to `CGEventTap` output also applies to these.
///
/// Two distinct subscriptions:
///
/// 1. **Clamshell** — `IOServiceAddInterestNotification` on `IOPMrootDomain`
///    fires for any general-interest power-management event. The callback
///    re-reads `AppleClamshellState` and only emits when the value actually
///    changes (the notification fires for many other transitions too).
///
/// 2. **Power source** — `IOPSNotificationCreateRunLoopSource` fires whenever
///    the system's notion of power source changes (AC ↔ battery) or the
///    capacity advances. We throttle: emit on AC/battery transitions and on
///    capacity jumps of ≥ 5% so `system_events` doesn't fill up with
///    one-percent-decrements.
public final class LidPowerObserver: @unchecked Sendable {

    private let clock: Clock
    private let queue: DispatchQueue

    // Clamshell state.
    private var notifyPort: IONotificationPortRef?
    private var rootService: io_service_t = 0
    private var clamshellInterest: io_object_t = 0
    private var lastClamshellClosed: Bool?

    // Power-source state.
    private var psRunLoopSource: CFRunLoopSource?
    private var lastIsOnBattery: Bool?
    private var lastPercent: Int?

    // Caller's sink. Captured under `lock`.
    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
        self.queue = DispatchQueue(label: "com.pulse.LidPowerObserver", qos: .utility)
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard self.handler == nil else { return }
        self.handler = handler
        startClamshellObserverLocked()
        startPowerSourceObserverLocked()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let psRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), psRunLoopSource, .defaultMode)
            self.psRunLoopSource = nil
        }
        if clamshellInterest != 0 {
            IOObjectRelease(clamshellInterest)
            clamshellInterest = 0
        }
        if rootService != 0 {
            IOObjectRelease(rootService)
            rootService = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        handler = nil
        lastClamshellClosed = nil
        lastIsOnBattery = nil
        lastPercent = nil
    }

    // MARK: - Test hooks
    //
    // Tests cannot drive IOKit on a CI runner. These hooks pump synthesized
    // transitions through the same emit path so the wiring between observer
    // and handler is exercised.

    public func simulateLidChanged(open: Bool, at instant: Date? = nil) {
        let when = instant ?? clock.now
        emit(open ? .lidOpened(at: when) : .lidClosed(at: when))
    }

    public func simulatePowerChanged(isOnBattery: Bool, percent: Int, at instant: Date? = nil) {
        let when = instant ?? clock.now
        emit(.powerChanged(isOnBattery: isOnBattery, percent: percent, at: when))
    }

    // MARK: - Clamshell

    private func startClamshellObserverLocked() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        IONotificationPortSetDispatchQueue(port, queue)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            IONotificationPortDestroy(port)
            return
        }

        notifyPort = port
        rootService = service
        lastClamshellClosed = readClamshellClosed(service: service)

        let context = Unmanaged.passUnretained(self).toOpaque()
        var notification: io_object_t = 0
        let status = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { (refCon, _, _, _) in
                guard let refCon else { return }
                let me = Unmanaged<LidPowerObserver>.fromOpaque(refCon).takeUnretainedValue()
                me.handleClamshellNotification()
            },
            context,
            &notification
        )
        if status == KERN_SUCCESS {
            clamshellInterest = notification
        }
    }

    private func handleClamshellNotification() {
        lock.lock()
        let svc = rootService
        let previous = lastClamshellClosed
        lock.unlock()
        guard svc != 0 else { return }
        guard let nowClosed = readClamshellClosed(service: svc) else { return }
        guard nowClosed != previous else { return }
        lock.lock(); lastClamshellClosed = nowClosed; lock.unlock()
        emit(nowClosed ? .lidClosed(at: clock.now) : .lidOpened(at: clock.now))
    }

    private func readClamshellClosed(service: io_service_t) -> Bool? {
        let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )
        return property?.takeRetainedValue() as? Bool
    }

    // MARK: - Power source

    private func startPowerSourceObserverLocked() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ refCon in
            guard let refCon else { return }
            let me = Unmanaged<LidPowerObserver>.fromOpaque(refCon).takeUnretainedValue()
            me.handlePowerSourceNotification()
        }, context) else {
            return
        }
        let source = unmanaged.takeRetainedValue()
        psRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // Seed baseline so the first real notification compares against
        // current reality, not nil.
        if let snapshot = readPowerSourceState() {
            lastIsOnBattery = snapshot.isOnBattery
            lastPercent = snapshot.percent
        }
    }

    private func handlePowerSourceNotification() {
        guard let snapshot = readPowerSourceState() else { return }
        lock.lock()
        let prevBattery = lastIsOnBattery
        let prevPercent = lastPercent
        lock.unlock()
        let stateChanged = (prevBattery != snapshot.isOnBattery)
        let percentJump = abs((prevPercent ?? snapshot.percent) - snapshot.percent) >= 5
        guard stateChanged || percentJump else { return }
        lock.lock()
        lastIsOnBattery = snapshot.isOnBattery
        lastPercent = snapshot.percent
        lock.unlock()
        emit(.powerChanged(isOnBattery: snapshot.isOnBattery, percent: snapshot.percent, at: clock.now))
    }

    private struct PowerSourceState {
        let isOnBattery: Bool
        let percent: Int
    }

    private func readPowerSourceState() -> PowerSourceState? {
        guard let blobUM = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobUM.takeRetainedValue()
        guard let listUM = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listUM.takeRetainedValue() as Array
        guard let firstSource = list.first else {
            // No batteries means a desktop Mac on permanent AC.
            return PowerSourceState(isOnBattery: false, percent: 100)
        }
        guard let descUM = IOPSGetPowerSourceDescription(blob, firstSource as CFTypeRef) else {
            return nil
        }
        let desc = descUM.takeUnretainedValue() as NSDictionary
        let stateString = desc[kIOPSPowerSourceStateKey] as? String ?? kIOPSACPowerValue
        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let isOnBattery = (stateString == kIOPSBatteryPowerValue)
        return PowerSourceState(isOnBattery: isOnBattery, percent: percent)
    }

    // MARK: - Emit

    private func emit(_ event: DomainEvent) {
        let copy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        copy = handler
        lock.unlock()
        copy?(event)
    }
}
#endif

import Foundation
import PulseCore

/// An `EventSource` that lets tests manually pump events. Replaces
/// `CGEventTap` in every scenario that does not specifically exercise the
/// platform adapter.
public final class FakeEventSource: EventSource, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable (DomainEvent) -> Void)?
    private(set) public var isRunning = false
    private(set) public var startCount = 0
    private(set) public var stopCount = 0

    public init() {}

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if isRunning {
            throw EventSourceError.alreadyRunning
        }
        self.handler = handler
        self.isRunning = true
        self.startCount += 1
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        self.isRunning = false
        self.stopCount += 1
    }

    /// Inject an event into the subscribed handler. No-op if `start` was not
    /// called.
    public func pump(_ event: DomainEvent) {
        let handlerCopy: (@Sendable (DomainEvent) -> Void)?
        lock.lock()
        handlerCopy = self.handler
        lock.unlock()
        handlerCopy?(event)
    }

    /// Convenience: pump a batch at once.
    public func pump(_ events: [DomainEvent]) {
        for event in events {
            pump(event)
        }
    }
}

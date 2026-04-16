import Foundation

/// An abstract event source. `CGEventTapSource` (macOS) and `FakeEventSource`
/// (tests) both conform. Consumers of events depend on this protocol, not on
/// `CGEventTap` directly — this is what makes the collection logic testable
/// off-device.
///
/// Lifecycle:
/// - `start(_:)` delivers events asynchronously until `stop()` is called.
/// - The handler MUST be thread-safe; implementations may invoke it on
///   any queue. Handlers that update shared state should hop to their own
///   actor or serial queue.
public protocol EventSource: Sendable {
    func start(handler: @escaping @Sendable (DomainEvent) -> Void) throws
    func stop()
}

/// An error that can occur when starting a source (e.g. missing permissions).
public enum EventSourceError: Error, Equatable, Sendable {
    case permissionDenied(Permission)
    case alreadyRunning
    case platformFailure(String)
}

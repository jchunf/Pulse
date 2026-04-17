import Foundation

/// Buffers `DomainEvent`s in memory and flushes them to `EventStore` in
/// batches. Decouples the high-frequency event source from disk I/O so we
/// pay one fsync per second rather than tens per second.
///
/// Flush triggers:
/// - Periodic: every `flushInterval` (default 1s) `flush()` is invoked by
///   the surrounding `CollectorRuntime`.
/// - Backpressure: if the buffer exceeds `maxBufferedEvents`, the next
///   `enqueue` triggers an immediate flush.
/// - Stop: `stop()` flushes remaining events synchronously.
///
/// The actor model ensures all state mutations are serialized; the writer
/// is safe to share across multiple producers.
public actor EventWriter {

    public let flushInterval: TimeInterval
    public let maxBufferedEvents: Int

    private let store: EventStore
    private let displayProvider: @Sendable () -> [DisplayInfo]
    private var pending: [WriteOperation] = []
    private var stats: WriterStats = .empty
    private var lastFlushAt: Date?

    public init(
        store: EventStore,
        displayProvider: @escaping @Sendable () -> [DisplayInfo],
        flushInterval: TimeInterval = 1.0,
        maxBufferedEvents: Int = 5_000
    ) {
        self.store = store
        self.displayProvider = displayProvider
        self.flushInterval = flushInterval
        self.maxBufferedEvents = maxBufferedEvents
    }

    /// Append an event for later persistence. Returns the resulting buffer
    /// size so callers can observe backpressure if they care.
    @discardableResult
    public func enqueue(_ event: DomainEvent) async -> Int {
        if let op = makeOperation(for: event) {
            pending.append(op)
        }
        if pending.count >= maxBufferedEvents {
            await flush()
        }
        return pending.count
    }

    /// Flush any buffered operations. Safe to call when the buffer is empty
    /// (no-op).
    public func flush() async {
        guard !pending.isEmpty else {
            stats = stats.recordingFlush(rows: 0, at: Date())
            lastFlushAt = Date()
            return
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        do {
            let written = try store.appendBatch(batch)
            stats = stats.recordingFlush(rows: written, at: Date())
            lastFlushAt = Date()
        } catch {
            // On failure, requeue at the head of the buffer so we don't lose
            // events. If the failure is persistent we'll back up until
            // `maxBufferedEvents` triggers another attempt.
            pending.insert(contentsOf: batch, at: 0)
            stats = stats.recordingFailure(error: error, at: Date())
        }
    }

    /// Final flush + buffer drop on shutdown.
    public func stop() async {
        await flush()
    }

    public var snapshot: WriterStats { stats }

    public var bufferedCount: Int { pending.count }

    // MARK: - Private

    private func makeOperation(for event: DomainEvent) -> WriteOperation? {
        let ts = Int64(event.timestamp.timeIntervalSince1970 * 1_000)
        switch event {
        case let .mouseMove(point, _):
            return .mouseMove(tsMillis: ts, displayId: point.displayId, xNorm: point.x, yNorm: point.y)
        case let .mouseClick(button, point, doubleClick, _):
            return .mouseClick(tsMillis: ts, displayId: point.displayId, xNorm: point.x, yNorm: point.y, button: button, isDouble: doubleClick)
        case let .mouseScroll(delta, horizontal, _):
            // Scroll events are recorded as system_events rather than a
            // dedicated raw table in V1. Payload encodes "<axis>:<delta>".
            // A dedicated raw_mouse_scroll table can arrive in a later
            // schema version if we need finer-grained analytics.
            let axis = horizontal ? "h" : "v"
            return .systemEvent(tsMillis: ts, category: "mouse_scroll", payload: "\(axis):\(delta)")
        case let .keyPress(keyCode, _):
            return .keyPress(tsMillis: ts, keyCode: keyCode)
        case let .foregroundApp(bundleId, _):
            return .systemEvent(tsMillis: ts, category: "foreground_app", payload: bundleId)
        case let .windowTitleHash(bundleId, hash, _):
            return .systemEvent(tsMillis: ts, category: "window_title", payload: "\(bundleId)|\(hash)")
        case .idleEntered:
            return .systemEvent(tsMillis: ts, category: "idle_entered", payload: nil)
        case .idleExited:
            return .systemEvent(tsMillis: ts, category: "idle_exited", payload: nil)
        case .systemSleep:
            return .systemEvent(tsMillis: ts, category: "sleep", payload: nil)
        case .systemWake:
            return .systemEvent(tsMillis: ts, category: "wake", payload: nil)
        case .screenLocked:
            return .systemEvent(tsMillis: ts, category: "lock", payload: nil)
        case .screenUnlocked:
            return .systemEvent(tsMillis: ts, category: "unlock", payload: nil)
        case .lidClosed:
            return .systemEvent(tsMillis: ts, category: "lid_closed", payload: nil)
        case .lidOpened:
            return .systemEvent(tsMillis: ts, category: "lid_opened", payload: nil)
        case let .powerChanged(isOnBattery, percent, _):
            let payload = "\(isOnBattery ? "battery" : "ac"):\(percent)"
            return .systemEvent(tsMillis: ts, category: "power", payload: payload)
        case .displayConfigChanged:
            // Snapshot every connected display whenever config changes.
            // The collector emits one event; the writer fans out into N
            // display_snapshots rows below by reading the current state.
            for info in displayProvider() {
                pending.append(.displaySnapshot(tsMillis: ts, info: info))
            }
            return .systemEvent(tsMillis: ts, category: "display_change", payload: nil)
        }
    }
}

/// Counters surfaced to the HealthPanel.
public struct WriterStats: Sendable, Equatable {
    public var totalRowsWritten: Int
    public var totalFlushes: Int
    public var lastFlushAt: Date?
    public var lastErrorDescription: String?
    public var lastErrorAt: Date?

    public static let empty = WriterStats(
        totalRowsWritten: 0,
        totalFlushes: 0,
        lastFlushAt: nil,
        lastErrorDescription: nil,
        lastErrorAt: nil
    )

    public func recordingFlush(rows: Int, at instant: Date) -> WriterStats {
        WriterStats(
            totalRowsWritten: totalRowsWritten + rows,
            totalFlushes: totalFlushes + 1,
            lastFlushAt: instant,
            lastErrorDescription: lastErrorDescription,
            lastErrorAt: lastErrorAt
        )
    }

    public func recordingFailure(error: Error, at instant: Date) -> WriterStats {
        WriterStats(
            totalRowsWritten: totalRowsWritten,
            totalFlushes: totalFlushes,
            lastFlushAt: lastFlushAt,
            lastErrorDescription: String(describing: error),
            lastErrorAt: instant
        )
    }
}

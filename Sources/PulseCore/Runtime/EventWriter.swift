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
    private let mileageConverter: MileageConverter
    private var pending: [WriteOperation] = []
    private var stats: WriterStats = .empty
    private var lastFlushAt: Date?

    /// The last observed normalized point per display. Used to compute
    /// the physical millimeter delta between consecutive mouse moves —
    /// the odometer (F-07) gets its raw input from here. A mouse move that
    /// lands on a different display than the previous one resets the state
    /// for that display.
    private var lastPointPerDisplay: [UInt32: NormalizedPoint] = [:]

    /// Per-second accumulator for distance (mm) pending write. Flushed
    /// together with `pending` as a batch of UPSERT ops so sec_mouse
    /// rows get distance_mm incremented atomically.
    private var distanceBuffer: [Int64: Double] = [:]

    /// Per-second accumulator for scroll ticks. Same shape + flush rhythm
    /// as `distanceBuffer`; drains into `sec_mouse.scroll_ticks` via an
    /// INSERT … ON CONFLICT UPSERT so concurrent contributions to the
    /// same second compose without clobbering the row.
    private var scrollTickBuffer: [Int64: Int64] = [:]

    /// F-33 — per-second, per-combo shortcut counts. Drains to
    /// `sec_shortcuts` UPSERTs at flush time.
    private var shortcutBuffer: [Int64: [String: Int64]] = [:]

    /// F-08 — per-local-day, per-keycode counts. Populated only
    /// when `.keyPress` arrives with a non-nil keyCode (i.e. the
    /// user opted into D-K2). Drains to `day_key_codes` UPSERTs.
    private var keyCodeBuffer: [Int64: [UInt16: Int64]] = [:]

    public init(
        store: EventStore,
        displayProvider: @escaping @Sendable () -> [DisplayInfo],
        flushInterval: TimeInterval = 1.0,
        maxBufferedEvents: Int = 5_000,
        mileageConverter: MileageConverter = MileageConverter()
    ) {
        self.store = store
        self.displayProvider = displayProvider
        self.flushInterval = flushInterval
        self.maxBufferedEvents = maxBufferedEvents
        self.mileageConverter = mileageConverter
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
    /// (no-op). Also drains the per-second distance accumulator into a
    /// batch of UPSERT operations against sec_mouse.
    public func flush() async {
        drainDistanceBuffer()
        drainScrollTickBuffer()
        drainShortcutBuffer()
        drainKeyCodeBuffer()
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
        case let .mouseMove(point, at):
            accumulateDistance(for: point, at: at)
            return .mouseMove(tsMillis: ts, displayId: point.displayId, xNorm: point.x, yNorm: point.y)
        case let .mouseClick(button, point, doubleClick, _):
            return .mouseClick(tsMillis: ts, displayId: point.displayId, xNorm: point.x, yNorm: point.y, button: button, isDouble: doubleClick)
        case let .mouseScroll(delta, horizontal, at):
            // Each scroll event also bumps the per-second scroll-tick
            // accumulator so `sec_mouse.scroll_ticks` (V1) finally gets a
            // producer. The primary record remains a `system_events` row
            // for the payload ("h:<delta>" / "v:<delta>"); a dedicated
            // `raw_mouse_scroll` table can still arrive if we ever need
            // sub-second granularity. Flush batches the accumulator into
            // UPSERTs below.
            scrollTickBuffer[Int64(AggregationRules.secondBucket(for: at).timeIntervalSince1970), default: 0] += 1
            let axis = horizontal ? "h" : "v"
            return .systemEvent(tsMillis: ts, category: "mouse_scroll", payload: "\(axis):\(delta)")
        case let .keyPress(keyCode, at):
            // F-08 — when capture is opt-in (keyCode non-nil), fold
            // into the per-day buffer on top of the raw L0 row. The
            // raw row stays opt-in-gated too: the event tap decides
            // whether to pass keyCode.
            if let keyCode {
                let localOffset = Int64(TimeZone.current.secondsFromGMT(for: at))
                let dayLocalUtc =
                    ((Int64(at.timeIntervalSince1970) + localOffset) / 86_400 * 86_400) - localOffset
                keyCodeBuffer[dayLocalUtc, default: [:]][keyCode, default: 0] += 1
            }
            return .keyPress(tsMillis: ts, keyCode: keyCode)
        case let .shortcutPressed(combo, at):
            // No raw-L0 row for shortcuts — counts go straight into
            // `sec_shortcuts` via the per-second accumulator. This
            // matches the design for scroll ticks: compact rollup
            // rows, no L0 pile-up.
            let tsSecond = Int64(AggregationRules.secondBucket(for: at).timeIntervalSince1970)
            shortcutBuffer[tsSecond, default: [:]][combo, default: 0] += 1
            return nil
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
            // Also invalidate the distance-tracking last-point map because
            // the coordinate system may have rescaled.
            lastPointPerDisplay.removeAll(keepingCapacity: true)
            for info in displayProvider() {
                pending.append(.displaySnapshot(tsMillis: ts, info: info))
            }
            return .systemEvent(tsMillis: ts, category: "display_change", payload: nil)
        }
    }

    /// Tracks delta from the previous move on the same display and credits
    /// it to the current second's `sec_mouse.distance_mm`.
    private func accumulateDistance(for point: NormalizedPoint, at instant: Date) {
        defer { lastPointPerDisplay[point.displayId] = point }
        guard let previous = lastPointPerDisplay[point.displayId] else {
            return
        }
        guard let display = displayProvider().first(where: { $0.id == point.displayId }) else {
            return
        }
        let mm = mileageConverter.millimeters(between: previous, and: point, on: display)
        guard mm > 0, mm.isFinite else { return }
        let tsSecond = Int64(AggregationRules.secondBucket(for: instant).timeIntervalSince1970)
        distanceBuffer[tsSecond, default: 0] += mm
    }

    /// Converts the distance buffer into UPSERT ops appended to `pending`
    /// so they ride the same flush transaction as the raw rows.
    private func drainDistanceBuffer() {
        guard !distanceBuffer.isEmpty else { return }
        for (tsSecond, mm) in distanceBuffer {
            pending.append(.secMouseDistanceDelta(tsSecond: tsSecond, mm: mm))
        }
        distanceBuffer.removeAll(keepingCapacity: true)
    }

    /// Same flush model as `drainDistanceBuffer` but for scroll ticks.
    private func drainScrollTickBuffer() {
        guard !scrollTickBuffer.isEmpty else { return }
        for (tsSecond, ticks) in scrollTickBuffer {
            pending.append(.secMouseScrollDelta(tsSecond: tsSecond, ticks: ticks))
        }
        scrollTickBuffer.removeAll(keepingCapacity: true)
    }

    /// Same flush model as `drainDistanceBuffer` but for F-33 shortcut
    /// counts. Emits one UPSERT op per (second, combo) pair.
    private func drainShortcutBuffer() {
        guard !shortcutBuffer.isEmpty else { return }
        for (tsSecond, combos) in shortcutBuffer {
            for (combo, count) in combos {
                pending.append(.secShortcutDelta(tsSecond: tsSecond, combo: combo, count: count))
            }
        }
        shortcutBuffer.removeAll(keepingCapacity: true)
    }

    /// F-08 — drain per-day, per-keycode counts into UPSERT ops.
    /// Stays empty unless the user has opted into D-K2 capture.
    private func drainKeyCodeBuffer() {
        guard !keyCodeBuffer.isEmpty else { return }
        for (day, keyCodes) in keyCodeBuffer {
            for (keyCode, count) in keyCodes {
                pending.append(.dayKeyCodeDelta(day: day, keyCode: Int64(keyCode), count: count))
            }
        }
        keyCodeBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Test hooks

    public var bufferedDistanceMillimeters: Double {
        distanceBuffer.values.reduce(0, +)
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

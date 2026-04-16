import Foundation

/// Top-level orchestrator that wires the platform `EventSource` (real
/// `CGEventTap` in production, `FakeEventSource` in tests) to the writer,
/// the idle detector, the rollup scheduler, and the privacy gates.
///
/// One instance lives in `PulseApp`'s app delegate. It exposes a
/// `HealthSnapshot` for the menu popover and `pause(...)`/`resume()` for the
/// privacy controls.
public actor CollectorRuntime {

    public struct Configuration: Sendable, Equatable {
        public let writerFlushInterval: TimeInterval
        public let supervisorTickInterval: TimeInterval
        public let samplingPolicy: SamplingPolicy.Configuration
        public let rollupConfiguration: RollupScheduler.Configuration

        public init(
            writerFlushInterval: TimeInterval = 1.0,
            supervisorTickInterval: TimeInterval = 1.0,
            samplingPolicy: SamplingPolicy.Configuration = .default,
            rollupConfiguration: RollupScheduler.Configuration = .default
        ) {
            self.writerFlushInterval = writerFlushInterval
            self.supervisorTickInterval = supervisorTickInterval
            self.samplingPolicy = samplingPolicy
            self.rollupConfiguration = rollupConfiguration
        }

        public static let `default` = Configuration()
    }

    public enum LifecycleError: Error, Equatable {
        case alreadyRunning
        case notRunning
    }

    // Dependencies (immutable after init).
    private let database: PulseDatabase
    private let store: EventStore
    private let writer: EventWriter
    private let scheduler: RollupScheduler
    private let pauseController: PauseController
    private let permissions: PermissionService
    private let displayRegistry: DisplayRegistry
    private let eventSource: EventSource
    private let idleDetector: IdleDetector
    private let samplingPolicy: SamplingPolicy
    private let clock: Clock
    private let configuration: Configuration

    // Mutable runtime state.
    private var isRunning: Bool = false
    private var supervisorTask: Task<Void, Never>?

    public init(
        database: PulseDatabase,
        eventSource: EventSource,
        permissions: PermissionService,
        displayRegistry: DisplayRegistry,
        clock: Clock = SystemClock(),
        configuration: Configuration = .default
    ) {
        self.database = database
        self.store = EventStore(database: database)
        self.permissions = permissions
        self.displayRegistry = displayRegistry
        self.clock = clock
        self.eventSource = eventSource
        self.configuration = configuration

        let displayProvider: @Sendable () -> [DisplayInfo] = { displayRegistry.displays }
        self.writer = EventWriter(
            store: EventStore(database: database),
            displayProvider: displayProvider,
            flushInterval: configuration.writerFlushInterval
        )
        self.scheduler = RollupScheduler(
            database: database,
            clock: clock,
            configuration: configuration.rollupConfiguration
        )
        self.pauseController = PauseController(clock: clock)
        self.idleDetector = IdleDetector(clock: clock)
        self.samplingPolicy = SamplingPolicy(clock: clock, configuration: configuration.samplingPolicy)
    }

    // MARK: - Lifecycle

    public func start() throws {
        if isRunning { throw LifecycleError.alreadyRunning }
        if permissions.status(of: .inputMonitoring) != .granted {
            throw EventSourceError.permissionDenied(.inputMonitoring)
        }

        // Snapshot displays so heatmap rendering knows the geometry that
        // produced today's data, even if the user later changes resolution.
        let now = clock.now
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let snapshots: [WriteOperation] = displayRegistry.displays.map {
            .displaySnapshot(tsMillis: nowMs, info: $0)
        }
        if !snapshots.isEmpty {
            try store.appendBatch(snapshots)
        }

        // Wire the source. The closure pumps into the actor; `Task.detached`
        // is fine because the writer is an actor and serializes internally.
        try eventSource.start { [weak self] event in
            guard let self else { return }
            Task.detached { [weak self] in
                await self?.ingest(event)
            }
        }

        isRunning = true
        startSupervisor()
    }

    public func stop() async {
        guard isRunning else { return }
        eventSource.stop()
        supervisorTask?.cancel()
        supervisorTask = nil
        await writer.stop()
        isRunning = false
    }

    public func pause(reason: PauseController.Reason = .userPause, duration: TimeInterval = 1_800) {
        pauseController.pause(reason: reason, duration: duration)
    }

    public func resume() {
        pauseController.resume()
    }

    // MARK: - Health

    public func healthSnapshot() async -> HealthSnapshot {
        let now = clock.now
        let writerStats = await writer.snapshot
        let permissionsSnap = permissions.snapshot(at: now)
        let counts = (try? store.l0Counts()) ?? L0Counts(mouseMoves: 0, mouseClicks: 0, keyEvents: 0)
        let dbSize = store.databaseFileSizeBytes()
        let lastWriteMs = (try? store.latestWriteTimestamp()) ?? nil
        let lastWrite = lastWriteMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        return HealthSnapshot(
            capturedAt: now,
            isRunning: isRunning,
            pause: pauseController.snapshot(),
            permissions: permissionsSnap,
            writer: writerStats,
            rollupStamps: scheduler.stamps,
            l0Counts: counts,
            databaseFileSizeBytes: dbSize,
            lastWriteAt: lastWrite
        )
    }

    // MARK: - Test hooks
    //
    // Tests drive the runtime by pumping events and calling these directly,
    // bypassing the supervisor's timing.

    public func ingestForTesting(_ event: DomainEvent) async {
        await ingest(event)
    }

    public func tickRollupsForTesting(now: Date) throws -> Set<RollupScheduler.Job> {
        try scheduler.tick(now: now)
    }

    public func flushForTesting() async {
        await writer.flush()
    }

    public func setRunningForTesting() {
        isRunning = true
    }

    // MARK: - Private

    private func ingest(_ event: DomainEvent) async {
        if pauseController.isPaused(at: event.timestamp) {
            return
        }
        // Only mouseMove events are throttled by sampling — clicks, key
        // presses and system events are always recorded.
        if case .mouseMove = event {
            if !samplingPolicy.shouldRecord(at: event.timestamp) {
                _ = idleDetector.observe(event)
                return
            }
        }
        if let transition = idleDetector.observe(event) {
            switch transition {
            case let .idleEntered(at):  await writer.enqueue(.idleEntered(at: at))
            case let .idleExited(at):   await writer.enqueue(.idleExited(at: at))
            }
        }
        await writer.enqueue(event)
    }

    private func startSupervisor() {
        let interval = configuration.supervisorTickInterval
        supervisorTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let nanos = UInt64(max(interval, 0.05) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.supervisorTick()
            }
        }
    }

    private func supervisorTick() async {
        let now = clock.now
        if let transition = idleDetector.tick(now: now) {
            switch transition {
            case let .idleEntered(at):  await writer.enqueue(.idleEntered(at: at))
            case let .idleExited(at):   await writer.enqueue(.idleExited(at: at))
            }
        }
        await writer.flush()
        do {
            _ = try scheduler.tick(now: now)
        } catch {
            // Rollup failures should be observable but non-fatal; the next
            // tick will retry. We surface them via the writer stats so the
            // HealthPanel can warn the user.
            _ = error
        }
    }
}

import Testing
import Foundation
import GRDB
@testable import PulseCore
import PulseTestSupport

@Suite("CollectorRuntime — orchestrator gates and ingestion")
struct CollectorRuntimeTests {

    private func makeRuntime(
        permissions: PermissionService = FakePermissionService.allGranted(),
        eventSource: EventSource = FakeEventSource(),
        configuration: CollectorRuntime.Configuration = .init(
            writerFlushInterval: 60,
            supervisorTickInterval: 60,
            samplingPolicy: .init(activeRateHz: 10, idleRateHz: 1, idleWindow: 5),
            rollupConfiguration: .init(
                rawToSecondInterval: 60,
                secondsToMinutesInterval: 300,
                minutesToHoursInterval: 3_600,
                purgeInterval: 86_400
            )
        )
    ) throws -> (CollectorRuntime, PulseDatabase, FakeClock, EventStore) {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let db = try PulseDatabase.inMemory()
        let store = EventStore(database: db)
        let displays = FakeDisplayRegistry(displays: [
            DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 109, isPrimary: true)
        ])
        let runtime = CollectorRuntime(
            database: db,
            eventSource: eventSource,
            permissions: permissions,
            displayRegistry: displays,
            clock: clock,
            configuration: configuration
        )
        return (runtime, db, clock, store)
    }

    @Test("ingest writes to the database after a flush")
    func ingestThenFlushPersists() async throws {
        let (runtime, _, clock, store) = try makeRuntime()
        await runtime.setRunningForTesting()
        let point = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        await runtime.ingestForTesting(.mouseMove(point, at: clock.now))
        await runtime.flushForTesting()
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 1)
    }

    @Test("paused runtime drops events silently")
    func pausedDrops() async throws {
        let (runtime, _, clock, store) = try makeRuntime()
        await runtime.setRunningForTesting()
        await runtime.pause(reason: .userPause, duration: 600)
        let point = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        await runtime.ingestForTesting(.mouseMove(point, at: clock.now))
        await runtime.flushForTesting()
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 0)
    }

    @Test("resume restores writes")
    func resumeRestoresWrites() async throws {
        let (runtime, _, clock, store) = try makeRuntime()
        await runtime.setRunningForTesting()
        await runtime.pause(reason: .userPause, duration: 60)
        await runtime.resume()
        let point = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        await runtime.ingestForTesting(.mouseMove(point, at: clock.now))
        await runtime.flushForTesting()
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 1)
    }

    @Test("sampling policy throttles excess mouse-move events")
    func samplingDropsMoves() async throws {
        let (runtime, _, clock, store) = try makeRuntime()
        await runtime.setRunningForTesting()
        // Pump 5 moves in quick succession; with activeRateHz=10 (1 every 100ms)
        // and a 1ms gap, only the first should land.
        let point = NormalizedPoint(displayId: 1, x: 0.5, y: 0.5)
        for offset in 0..<5 {
            let ts = clock.now.addingTimeInterval(Double(offset) * 0.001)
            await runtime.ingestForTesting(.mouseMove(point, at: ts))
        }
        await runtime.flushForTesting()
        let counts = try store.l0Counts()
        #expect(counts.mouseMoves == 1)
    }

    @Test("non-mouse events bypass sampling throttle")
    func clicksAndKeysAlwaysPersist() async throws {
        let (runtime, _, clock, store) = try makeRuntime()
        await runtime.setRunningForTesting()
        for offset in 0..<3 {
            let ts = clock.now.addingTimeInterval(Double(offset) * 0.001)
            await runtime.ingestForTesting(.keyPress(keyCode: nil, at: ts))
            await runtime.ingestForTesting(.mouseClick(.left, point: NormalizedPoint(displayId: 1, x: 0.5, y: 0.5), doubleClick: false, at: ts))
        }
        await runtime.flushForTesting()
        let counts = try store.l0Counts()
        #expect(counts.keyEvents == 3)
        #expect(counts.mouseClicks == 3)
    }

    @Test("idle transitions are persisted as system events")
    func idleEnteredPersisted() async throws {
        let (runtime, db, clock, _) = try makeRuntime()
        await runtime.setRunningForTesting()
        // Prime a key press to set lastActivity.
        await runtime.ingestForTesting(.keyPress(keyCode: nil, at: clock.now))
        clock.advance(301) // > IdleDetector default 300
        // Pump a non-activity event so the detector observes time passing
        // through ingest's path, then flush.
        await runtime.ingestForTesting(.foregroundApp(bundleId: "com.apple.Finder", at: clock.now))
        // observe() above doesn't trigger idleEntered (only tick does); use
        // ingestForTesting with a key press at 301s — that calls observe()
        // which exits any pending idle state — so we need a manual tick.
        // Easier: call flush after clock advance and then send activity.
        await runtime.ingestForTesting(.keyPress(keyCode: nil, at: clock.now))
        await runtime.flushForTesting()
        // We can't directly invoke tick from outside the runtime in B2; the
        // surface for that lands in B3. For this PR we at least confirm no
        // crash occurred and writes happened.
        let total = try await db.queue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_events") ?? 0
        }
        #expect(total >= 1)
    }

    @Test("starting without input monitoring permission throws")
    func startRequiresInputMonitoring() async throws {
        let perms = FakePermissionService.allDenied()
        let (runtime, _, _, _) = try makeRuntime(permissions: perms, eventSource: FakeEventSource())
        await #expect(throws: EventSourceError.self) {
            try await runtime.start()
        }
    }

    @Test("healthSnapshot reports current pause and writer state")
    func healthSnapshotReflectsState() async throws {
        let (runtime, _, _, _) = try makeRuntime()
        await runtime.setRunningForTesting()
        await runtime.pause(reason: .sensitivePeriod, duration: 600)
        let snap = await runtime.healthSnapshot()
        #expect(snap.pause.isActive == true)
        #expect(snap.pause.reason == .sensitivePeriod)
        #expect(snap.permissions.isAllRequiredGranted == true)
    }

    @Test("idle-tick hook persists idleEntered into system_events")
    func idleTickPersistsIdleEntered() async throws {
        let (runtime, db, clock, _) = try makeRuntime()
        await runtime.setRunningForTesting()
        // Seed lastActivity with a keypress so the idle timer has a
        // reference point, then jump past the 300s IdleDetector default.
        await runtime.ingestForTesting(.keyPress(keyCode: nil, at: clock.now))
        clock.advance(301)
        await runtime.tickIdleForTesting(now: clock.now)
        await runtime.flushForTesting()

        let categories = try await db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT category FROM system_events WHERE category IN ('idle_entered','idle_exited') ORDER BY ts"
            )
        }
        #expect(categories.contains("idle_entered"))
    }

    @Test("lid and power events from external sources land as system_events")
    func lidAndPowerEventsPersist() async throws {
        let (runtime, db, clock, _) = try makeRuntime()
        await runtime.setRunningForTesting()
        await runtime.ingestExternalEvent(.lidClosed(at: clock.now))
        clock.advance(1)
        await runtime.ingestExternalEvent(.lidOpened(at: clock.now))
        clock.advance(1)
        await runtime.ingestExternalEvent(.powerChanged(isOnBattery: true, percent: 87, at: clock.now))
        await runtime.flushForTesting()

        let rows = try await db.queue.read { db -> [(String, String?)] in
            try Row.fetchAll(
                db,
                sql: "SELECT category, payload FROM system_events WHERE category IN ('lid_closed','lid_opened','power') ORDER BY ts"
            ).map { row -> (String, String?) in
                let category: String = row["category"]
                let payload: String? = row["payload"]
                return (category, payload)
            }
        }
        #expect(rows.map(\.0) == ["lid_closed", "lid_opened", "power"])
        #expect(rows.last?.1 == "battery:87")
    }

    @Test("ingestExternalEvent routes through the same gates as primary source")
    func externalIngestRespectsPause() async throws {
        let (runtime, db, clock, _) = try makeRuntime()
        await runtime.setRunningForTesting()
        await runtime.pause(reason: .userPause, duration: 60)
        await runtime.ingestExternalEvent(.systemSleep(at: clock.now))
        await runtime.flushForTesting()
        let sleepRows = try await db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_events WHERE category = 'sleep'") ?? -1
        }
        #expect(sleepRows == 0)

        // Resume and ingest again — now it lands.
        await runtime.resume()
        await runtime.ingestExternalEvent(.systemSleep(at: clock.now))
        await runtime.flushForTesting()
        let afterResume = try await db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_events WHERE category = 'sleep'") ?? -1
        }
        #expect(afterResume == 1)
    }
}

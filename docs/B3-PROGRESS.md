# B3 Progress — Collector Completion

> Delivered under branch `claude/b3-collector-completion`. Builds on B2
> (`docs/B2-PROGRESS.md`).

## Scope

B3 closes the gap between "events flow" (B2) and "collected data is
complete and testable end-to-end". Three focused slices:

1. **Distance accumulation** — the writer now turns consecutive
   `NormalizedPoint`s on the same display into millimeter deltas and
   streams them into `sec_mouse.distance_mm`. Mileage (F-07) finally
   has real numbers behind it.

2. **Idle-tick test hook** — tests can now drive
   `IdleDetector.tick(now:)` through a `CollectorRuntime` surface and
   assert that `idleEntered` lands in `system_events` end-to-end.

3. **System event emitter** — sleep / wake / screen-lock / screen-unlock
   arrive via `NSWorkspace` + `DistributedNotificationCenter` and flow
   through the same ingest pipeline as CGEventTap output, so pause
   gating still applies.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Runtime/EventWriter.swift` | Per-display last-point cache + per-second distance buffer. `accumulateDistance(for:at:)` credits physical mm to the active second bucket; `drainDistanceBuffer()` turns the buffer into UPSERT ops at flush time. `displayConfigChanged` resets the cache. |
| `Runtime/CollectorRuntime.swift` | New `tickIdleForTesting(now:)` test hook + `ingestExternalEvent(_:)` public API so platform emitters feed into the same gating (pause / sampling / idle) as the primary event source. |
| `Storage/EventStore.swift` | New `WriteOperation.secMouseDistanceDelta(tsSecond:mm:)` with `INSERT … ON CONFLICT DO UPDATE` SQL so multiple writers can credit the same second without collisions. |

### PulsePlatform

| Path | Change |
|---|---|
| `SystemEventEmitter.swift` | New. Registers observers on `NSWorkspace.shared.notificationCenter` (willSleep/didWake/screensDidSleep/screensDidWake) and `DistributedNotificationCenter.default()` (com.apple.screenIsLocked/Unlocked). Emits `systemSleep` / `systemWake` / `screenLocked` / `screenUnlocked` `DomainEvent`s. |
| `PulsePlatform.swift` | `buildFingerprint` bumped to `pulse-b3-collector-completion`. |

### PulseApp

- AppDelegate owns a `SystemEventEmitter` and a `NSWorkspaceAppWatcher`.
- `applicationDidFinishLaunching` → `bootCollector` starts them and
  pipes their events through `runtime.ingestExternalEvent` so they
  respect the same pause gate.
- `applicationWillTerminate` tears them down.

### Tests (Swift Testing, ~7 new cases)

| Suite | New Cases |
|---|---|
| `DistanceAccumulationTests` (new file) | 5: first-move-credits-nothing, two-moves-accumulate, per-second bucketing, display-change invalidates cache, per-display isolation |
| `CollectorRuntimeTests` (extended) | 2: `idleTickPersistsIdleEntered`, `externalIngestRespectsPause` (pause-gates external events, unpause lets them through) |

## 🟡 Intentionally stubbed (B4 scope)

1. **Lid open/close & power change** — IOKit-based detection. The
   DomainEvent cases and writer translation exist; B4 adds the
   IOKit observer in PulsePlatform.
2. **Title-change AX notifications** — today the window title hash
   is only re-read on `NSWorkspace` app activation. AX notifications
   for title changes within the same app are B4.
3. **Settings UI and onboarding flow** — deferred to a dedicated UX
   milestone; the pause API on the runtime is ready to be wired to a
   menu item the moment the UI lands.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test
  happens on the GitHub Actions macOS-14 / macOS-15 matrix.
- Local-developer loop unchanged: `make build && make test`.

## Related documents

- B1 → `B1-PROGRESS.md`
- B2 → `B2-PROGRESS.md`
- Architecture reference → `04-architecture.md`
- Data layout → `03-data-collection.md`
- Privacy → `05-privacy.md`

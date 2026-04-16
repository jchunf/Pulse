# B2 Progress — Live Collector

> Delivered under branch `claude/b2-live-collector`. Builds on B1
> (`docs/B1-PROGRESS.md`).

## Scope

B2 turns the B1 scaffold into a **live, end-to-end collector**: events
flow from `CGEventTap` → `CollectorRuntime` → `EventWriter` → SQLite, with
a `RollupScheduler` aggregating L0 raw rows into L1/L2/L3 buckets on a
timer. The menu-bar `HealthPanel` shows counts, last-write timestamp and
DB size so the user (and we) can verify the pipeline is alive without
attaching a debugger.

Privacy primitives — `PauseController` and `TitleHasher` — also land here
so any future feature can rely on them being part of the runtime contract,
not retrofitted.

---

## ✅ Delivered

### PulseCore — new modules

| Path | What it does |
|---|---|
| `Privacy/PauseController.swift` | Auto-resuming pause window for both user-pause (default 30 min) and sensitive-period (F-46). Drops events silently when active. |
| `Privacy/TitleHasher.swift` | SHA-256 of window titles, plus a force-redact sentinel for high-sensitivity apps. |
| `Sampling/SamplingPolicy.swift` | Adaptive throttle: 30 Hz when active, 1 Hz after `idleWindow` of inactivity. Only mouse moves are throttled — clicks, keys and system events always persist. |
| `Storage/EventStore.swift` | Typed facade over GRDB with `WriteOperation` enum + read helpers (`l0Counts`, `latestWriteTimestamp`, `databaseFileSizeBytes`). |
| `Runtime/EventWriter.swift` | Actor-based buffered writer; periodic + backpressure flush, atomic batches, structured `WriterStats`. |
| `Runtime/RollupScheduler.swift` | Periodic SQL rollups (raw → sec → min → hour) and retention purges. Idempotent UPSERTs. |
| `Runtime/CollectorRuntime.swift` | Top-level actor that wires `EventSource` + `IdleDetector` + `SamplingPolicy` + `PauseController` + writer + scheduler. Exposes `start/stop/pause/resume` and a `HealthSnapshot` for the UI. |
| `Health/HealthSnapshot.swift` | Status payload for the menu popover: counts, headline, "silently failing" detector. |

### PulsePlatform — new + extended

| Path | What it does |
|---|---|
| `AccessibilityWindowReader.swift` | Reads frontmost-window title via `AXUIElement` and emits a `windowTitleHash` event; force-redacts known sensitive bundles (Messages, 1Password, etc.). |
| `NSWorkspaceAppWatcher.swift` (extended) | After every app activation, optionally calls the window reader and emits a follow-up `windowTitleHash` event. |
| `PulsePlatform.swift` (extended) | Adds `displayRegistry()` factory; updates `buildFingerprint`. |

### PulseApp — wired

- AppDelegate constructs `PulseDatabase` (from `~/Library/Application Support/Pulse/pulse.db`), `CGEventTapSource`, and `CollectorRuntime`.
- `applicationDidFinishLaunching` boots the collector in a `Task` and starts a 1 s polling task that pulls `HealthSnapshot` into the SwiftUI model.
- `HealthMenuView` shows status headline, raw-row counts, last-write age, DB size, and per-permission status; menu-bar icon switches between heartbeat / pause / warning depending on state.

### Tests (Swift Testing — all opt-in for nightly benchmarks)

| Suite | Cases |
|---|---|
| `PauseControllerTests` | 7 |
| `TitleHasherTests` | 6 |
| `SamplingPolicyTests` | 4 |
| `EventStoreTests` | 9 |
| `EventWriterTests` | 5 |
| `RollupSchedulerTests` | 7 |
| `CollectorRuntimeTests` | 8 |
| `HealthSnapshotTests` | 8 |
| `WriterBenchmarks` (env-gated) | 2 |

Adds **~54 new test cases**, all running under Swift Testing per Q-11.
Combined with B1's 46, the suite is now ~100 cases.

### CI / tooling

- `.github/workflows/nightly.yml` — runs on a 06:00 UTC cron and on
  manual dispatch; sets `PULSE_RUN_BENCHMARKS=1` so the env-gated
  benchmark suite executes against the latest macOS runner.
- The PR CI in `.github/workflows/ci.yml` is unchanged — benchmarks stay
  out of the PR loop.

---

## 🟡 Intentionally stubbed (next PR)

1. **Idle-tick exposure for tests** — the supervisor calls
   `IdleDetector.tick(now:)` every second, but tests can't drive ticks
   today. B3 adds a `tickIdleForTesting(now:)` hook so we can assert
   `idleEntered` persistence end-to-end.
2. **Settings UI** — preferences pane is still the placeholder. The
   "敏感时段快捷键" / "Pause for 30 min" actions exist on the runtime but
   have no menu items yet.
3. **Distance accumulation** — `sec_mouse.distance_mm` and friends are
   wired in the schema but the writer doesn't yet compute incremental
   distance between consecutive moves on the same display. Plan for B3:
   the writer remembers the last `NormalizedPoint` per display and adds
   `MileageConverter.millimeters(between:and:on:)` into a per-second
   bucket on flush.
4. **Onboarding flow** — app currently launches straight into the menu
   bar. The 5-step `06-onboarding-permissions.md` flow lands in phase A.
5. **Window title change observation** — only re-read on `NSWorkspace`
   activation. AX notifications for title changes within the same app
   come in B3.
6. **Power / sleep / lid events** — no live emitter yet for `.systemSleep`
   et al. The schema, writer translation and tests are in place, so
   adding a `NSWorkspace` notification emitter in B3 is a couple of files.

---

## 🧪 Verification

- This branch was assembled in a Linux environment (no Swift toolchain).
  The new code follows the same conservative pattern as B1: GRDB's
  documented 6.x API surface, Swift Testing public types, and
  Foundation/AppKit standard library symbols only. Real compilation +
  test happens on the GitHub Actions macOS-14 / macOS-15 matrix.

- Local-developer flow on macOS unchanged:

  ```bash
  swift package resolve
  swift build
  swift test --parallel --enable-code-coverage
  ```

- Benchmarks run on demand (or in `nightly.yml`):

  ```bash
  PULSE_RUN_BENCHMARKS=1 swift test --filter "WriterBenchmarks"
  ```

---

## 🔜 Next PR (B3) candidates

- Idle-tick test hook + end-to-end idle persistence test
- Distance accumulation in the writer
- AX-notification-based window title change observer
- Sleep / wake / lid / power emitters via `NSWorkspace`
- Settings UI scaffold with the pause / sensitive-period buttons wired
- Initial onboarding flow (welcome + 2 permission steps)
- Coverage reporter PR-comment integration

---

## Related documents

- B1 progress (foundation) → `B1-PROGRESS.md`
- Architecture reference → `04-architecture.md`
- Data layout → `03-data-collection.md`
- Privacy red lines → `05-privacy.md`
- Test / CI policy → `10-testing-and-ci.md`
- UX principles → `11-ux-principles.md`

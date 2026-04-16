# B1 Progress — Foundations

> Delivered under branch `claude/b1-foundations`. This document tracks what
> the PR ships, what is intentionally stubbed, and what the next PR (B2)
> picks up.

## Scope reminder (from `08-roadmap.md`)

B1 is the **data底子**: schema + collector interfaces + aggregator rules +
fake doubles + CI wiring. No live CGEventTap, no real dashboard. The test
suite must be green on both macOS 14 and 15 before anything B2 ships.

---

## ✅ Delivered

### Package structure

- `Package.swift` — SPM package targeting macOS 14+, Swift 5.10+
- Four targets:
  - **PulseCore** — platform-independent domain logic
  - **PulsePlatform** — macOS adapters, guarded by `#if canImport(AppKit)`
  - **PulseTestSupport** — fakes / test doubles
  - **PulseApp** — executable (SwiftUI menu bar stub)
- Dependencies pinned:
  - `GRDB.swift ≥ 6.29.0` (SQLite layer)
  - `swift-snapshot-testing ≥ 1.17.0` (for future UI regression tests)

### Core protocols & types (PulseCore)

| File | Purpose |
|---|---|
| `Clock/Clock.swift` | `Clock` protocol + `SystemClock` production impl |
| `Events/DomainEvent.swift` | Rich enum of every event Pulse observes; `MouseButton` |
| `Events/EventSource.swift` | `EventSource` protocol + `EventSourceError` |
| `Permissions/PermissionService.swift` | `Permission`, `PermissionStatus`, `PermissionService`, `PermissionSnapshot` |
| `Display/DisplayInfo.swift` | `DisplayInfo`, `NormalizedPoint` |
| `Display/DisplayRegistry.swift` | `DisplayRegistry` protocol + `CoordNormalizer` (the critical `[0,1]` normalization) |
| `Mileage/MileageConverter.swift` | Pixel → mm/m/km conversion |
| `Mileage/LandmarkComparison.swift` | Dramatic-landmark picker for F-07 odometer |
| `Aggregation/AggregationRules.swift` | Second/minute/hour/day bucketing + retention cutoffs |
| `Idle/IdleDetector.swift` | 5-minute inactivity state machine |
| `Storage/Database.swift` | `PulseDatabase` wrapper over `DatabaseQueue` (WAL mode, pragmas) |
| `Storage/Migrator.swift` | Filename-driven `V{n}__name.sql` migrator |
| `Resources/Migrations/V1__initial.sql` | Schema: 14 tables for L0–L3 + system events + display snapshots |

### Test support (PulseTestSupport)

- `FakeClock` — deterministic time, `.advance(_:)`
- `FakeEventSource` — manual `pump(_:)` injection
- `FakePermissionService` — full state control, `.allGranted() / .allDenied()`
- `FakeDisplayRegistry` — in-memory displays arranged left-to-right

### Tests (PulseCoreTests — all written with Swift Testing per Q-11)

| Suite | File | Assertions |
|---|---|---|
| `CoordNormalizer` | `CoordNormalizerTests.swift` | 10 cases incl. parameterized roundtrip |
| `MileageConverter` / `LandmarkLibrary` | `MileageConverterTests.swift` | 12 cases incl. DPI conversion, dramatic-landmark monotonicity sweep |
| `AggregationRules` | `AggregationRulesTests.swift` | 8 cases (bucketing, idempotence, retention) |
| `IdleDetector` | `IdleDetectorTests.swift` | 9 state-machine cases |
| `Migrator` + `BundledMigrations` | `MigratorTests.swift` | 7 cases (filename parsing, in-memory schema checks, idempotence) |

### Platform adapters (PulsePlatform, `#if canImport(AppKit)`)

| File | Status |
|---|---|
| `SystemPermissionService.swift` | **live** — calls `IOHIDCheckAccess` + `AXIsProcessTrusted` |
| `LiveDisplayRegistry.swift` | **live** — `CGGetOnlineDisplayList` + reconfiguration callback |
| `CGEventTapSource.swift` | **scaffold** — creates tap, wires callbacks, emits `mouseMove/mouseClick/scrollWheel/keyPress`. Keycode capture gated to `nil` (Q-06). Scroll delta left at 0. |
| `NSWorkspaceAppWatcher.swift` | **live** — emits `foregroundApp(bundleId:)` on app activation |
| `PulsePlatform.swift` | facade for executable target |

### App (PulseApp)

- SwiftUI `@main` with `MenuBarExtra` (window style)
- `AppDelegate` switches to `.accessory` activation policy (Dock-less)
- `PermissionSnapshotProvider` observable wrapper
- `MenuBarContent` view shows permission statuses + Quit
- `SettingsPlaceholder` wires the Settings scene (content in a later PR)

### Tooling

- `.github/workflows/ci.yml` — macOS 14 + 15 matrix, build, test, coverage report, lint
- `scripts/lint.sh` — privacy red-line grep (forbids `NSPasteboard.general.string/data/propertyList` and `CGWindowListCreateImage` in Swift sources), suspicious-TODO check
- `.gitignore`, `.swiftformat`, `Makefile` with common targets (`build`, `test`, `lint`, `open`)

---

## 🟡 Intentionally stubbed (B2 scope)

1. **Real event persistence** — `CGEventTapSource` emits `DomainEvent`s but no one persists them yet. B2 introduces an `EventWriter` actor + GRDB batch inserts with a 1-second flush window.
2. **Adaptive sampling** — 30Hz → 1Hz idle fallback described in `04-architecture.md#4.2`. Scaffold lives in `IdleDetector` but the timer-driven sampler is B2.
3. **Double-click detection** — `CGEventTapSource` passes `doubleClick: false` unconditionally.
4. **Keycode capture (D-K2)** — `keyPress` emits `keyCode: nil` per Q-06. Opt-in flow + storage added in B2 alongside Settings.
5. **Window title hashing** — Accessibility API read + SHA-256 hashing landed in B2 (privacy design finalized; just not wired).
6. **Rollup jobs** — `AggregationRules` has the pure math. B2 wires the periodic `Scheduler` + SQL `INSERT ... ON CONFLICT` upserts.
7. **Onboarding views** — Only the menu popover is present; the 5-step onboarding flow (`06-onboarding-permissions.md`) lands in the A phase.
8. **Dashboard** — F-02 / F-03 / F-07 views come in A.
9. **Release signing / Sparkle** — `07-distribution.md` will become a real `release.yml` once we have an artifact worth signing.

---

## 📐 Coverage targets (from `10-testing-and-ci.md#四` / Q-14)

| Module | Target | B1 status (expected after first CI run) |
|---|---|---|
| `Clock` | 100% | fully covered by tests |
| `DomainEvent` | 90% | `isUserActivity`/`timestamp` covered via IdleDetector tests |
| `CoordNormalizer` | 100% | fully covered |
| `MileageConverter` / `LandmarkLibrary` | ≥ 95% | fully covered |
| `AggregationRules` | ≥ 95% | fully covered |
| `IdleDetector` | ≥ 95% | fully covered |
| `Migrator` / `BundledMigrations` | ≥ 95% | fully covered |
| `PulsePlatform.*` | — (platform code, covered by hand smoke tests) | not exercised in CI |
| **Core overall** | ≥ 90% | **expected pass** |

Coverage numbers above are expectations until CI runs on GitHub's macOS
runners (this workspace has no Swift toolchain — see "Verification" below).

---

## 🧪 Verification

This branch was assembled in a Linux environment that has **no Swift
toolchain installed**. The code has been written conservatively (standard
Foundation / GRDB 6 / Swift Testing APIs) and verified statically; final
compile / test validation happens on the GitHub Actions macOS runners
configured in `.github/workflows/ci.yml`.

To verify locally on a Mac:

```bash
git fetch origin claude/b1-foundations
git checkout claude/b1-foundations
swift package resolve
swift build
swift test --parallel --enable-code-coverage
make lint
```

Or open in Xcode: `open Package.swift`.

If any test fails due to an API shift in GRDB or Swift Testing between
what was written and what the runner installs, the fix-forward is cheap —
all affected logic is pure and isolated. Open follow-up Issues and we'll
land patches against this branch before proceeding to B2.

---

## 🔜 Next PR (B2) — "live collector"

- Wire `CGEventTapSource` + `NSWorkspaceAppWatcher` + `LiveDisplayRegistry`
  into a `CollectorRuntime` actor
- `EventWriter` actor that batches events to GRDB with a 1-second flush
- Adaptive sampling (`SamplingPolicy`)
- Rollup `Scheduler` that runs `AggregationRules` on a periodic cadence
- `HealthPanelViewModel` — exposes the counters, last-write timestamp, DB
  size, and permission snapshot to the menu popover (F-49)
- 24h simulated load benchmark under `PulseCoreTests/BenchmarksTests.swift`
  (marked `.disabled` in normal CI, enabled in nightly)

---

## Related documents

- `04-architecture.md` — the decisions this PR implements
- `10-testing-and-ci.md` — TDD + CI reference
- `08-roadmap.md#B1` — the work this PR checks off

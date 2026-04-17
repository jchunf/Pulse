# B4 Progress — Platform Observers

> Delivered under branch `claude/check-progress-XvlUY`. Builds on B3
> (`docs/B3-PROGRESS.md`).

## Scope

B4 closes the two B3-deferred IOKit / AX observer items so the runtime sees
every system event the schema already has columns for. Settings UI and
onboarding flow are intentionally **not** in B4 — those belong to a
dedicated UX milestone.

Two focused slices:

1. **`LidPowerObserver`** — IOKit-driven detection of clamshell open/close
   and AC ↔ battery transitions. Fills the `lid_closed` / `lid_opened` /
   `power` system_event categories that B3 left as DomainEvent cases without
   producers.

2. **`AccessibilityTitleObserver`** — `AXObserver`-driven detection of
   window title changes within a single app, complementing the
   `NSWorkspaceAppWatcher` path that only re-reads the title on app
   activation.

Both observers feed events through `CollectorRuntime.ingestExternalEvent`,
so pause / sampling / idle gating still apply.

## ✅ Delivered

### PulsePlatform

| Path | Change |
|---|---|
| `LidPowerObserver.swift` | New. Two subscriptions: `IOServiceAddInterestNotification` on `IOPMrootDomain` (re-reads `AppleClamshellState` on each general-interest fire and emits `lidOpened`/`lidClosed` only on actual transitions) + `IOPSNotificationCreateRunLoopSource` for AC/battery transitions (throttled — emit only on AC↔battery flip or capacity jump ≥ 5%). Test hooks `simulateLidChanged` / `simulatePowerChanged` bypass IOKit so CI can exercise the handler wiring. |
| `AccessibilityTitleObserver.swift` | New. Subscribes to `NSWorkspace.didActivateApplicationNotification` and rebuilds an `AXObserver` for each newly-frontmost app, registering for `kAXTitleChangedNotification` on the focused window plus `kAXFocusedWindowChangedNotification` on the app element. Emits `windowTitleHash` events through `AccessibilityWindowReader` (so force-redact + hashing still apply). Same-hash dedup so docs whose title flickers don't spam `system_events`. Test hook `simulateTitleChanged(bundleId:titleSHA256:)` exercises the dedup path without AX. |
| `PulsePlatform.swift` | `buildFingerprint` bumped to `pulse-b4-platform-observers`. |

### PulseApp

- `AppDelegate` now owns `LidPowerObserver` + `AccessibilityTitleObserver`.
- `bootCollector` starts both with the same `feed` closure as the B3
  emitters (`runtime.ingestExternalEvent`).
- `applicationWillTerminate` tears them down.

### Tests (Swift Testing, ~10 new cases)

| Suite | New cases |
|---|---|
| `LidPowerObserverTests` (new) | 3: lid events reach handler, power event payload is correct, post-stop simulations are dropped |
| `AccessibilityTitleObserverTests` (new) | 6: first emit, identical-dedup, new-hash emits, cross-bundle same-hash emits, reset cache re-emits, post-stop drops |
| `CollectorRuntimeTests` (extended) | 1: `lidAndPowerEventsPersist` asserts external lid/power events round-trip into `system_events` with the correct categories + payload |

## 🟡 Intentionally deferred

1. **Settings UI** — preference panel + collection toggles + privacy
   controls. Belongs to a dedicated UX milestone; the underlying
   `runtime.pause(reason:duration:)` API is already stable so the UI is a
   pure View-layer concern.
2. **Onboarding flow** — Welcome → Privacy promise → Input Monitoring →
   Accessibility → Done. Same milestone as Settings.
3. **Power-source change throttle tuning** — current 5% capacity threshold
   is a guess. Real data from B-track verification will inform whether to
   tighten or loosen it.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test
  happens on the GitHub Actions macos-14 / macos-15 matrix.
- Local-developer loop unchanged: `make build && make test`.
- Manual verification of the IOKit / AX paths requires a real Mac with
  granted Accessibility access — those paths are exercised by running
  `PulseApp` and watching `HealthSnapshot` counters tick.

## Related documents

- B1 → `B1-PROGRESS.md`
- B2 → `B2-PROGRESS.md`
- B3 → `B3-PROGRESS.md`
- Architecture reference → `04-architecture.md`
- Data layout → `03-data-collection.md`
- Privacy → `05-privacy.md`

# A5 Progress — Pause Controls (F-46 basic)

> Delivered under branch `claude/check-progress-XvlUY`. Fifth A-track
> slice. Builds on A1–A4. `PauseController` lands in B2; A5 is the
> missing UI surface.

## Scope

Surface the existing `PauseController` through the menu bar so the user
can explicitly pause collection without quitting the app. Three
preset durations (15 / 30 / 60 minutes) cover the common cases; the
controller itself already auto-resumes when the timer elapses, so no
follow-up poll is needed. "Resume now" cancels the active pause
early.

A system-wide hotkey registration (the full F-46 scope) is
**deferred** to a later UX slice — registering a global shortcut
without adding an Apple-event or privilege prompt is its own
investigation.

## ✅ Delivered

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | `AppDelegate` exposes `pauseCollector(duration:)` + `resumeCollector()` as fire-and-forget MainActor methods that hop into the `CollectorRuntime` actor. `HealthMenuView` takes two closures (`onPause` / `onResume`) and renders a new `PauseControlsView` between the counters and the permissions list. |
| `PulseApp.swift` | New `PauseControlsView`. Two states — if paused, shows a "Paused — resumes in Xm Ys" label with an orange icon plus a "Resume now" button; if idle, shows a "Pause collection…" menu with 15m / 30m / 1h presets. Countdown formatter falls back to seconds under a minute. |
| `PulseApp.swift` | Menu bar icon already switched to `pause.circle` via `HealthModel.menuBarIconName` whenever `snapshot.pause.isActive` — now that flag actually gets set by user action. |

### Tests

No new Swift Testing cases. `PauseControllerTests` (B2, 7 cases) already
covers pause semantics (duration extension, no-shortening, auto-resume,
`resume()` cancel, concurrent isolation). The A5 work is pure View +
wiring, which lives outside the unit-test surface per
`docs/10-testing-and-ci.md#二`.

## 🟡 Intentionally deferred

1. **System-wide hotkey (full F-46)** — registering `⌃⇧P` as a global shortcut. Needs either Carbon's `RegisterEventHotKey` or a Services-menu entry; each carries its own UX cost. Separate slice.
2. **Sensitive-period schedules** — "Pause every weekday from 19:00 to 22:00" recurring rules. Lives with Settings.
3. **Custom duration picker** — today limited to 15 / 30 / 60 min. "Until tomorrow morning" / arbitrary sliders follow in Settings.
4. **Dashboard pause banner** — when paused, the Dashboard window shows the same info as the menu bar. Simple View addition; keep out of this PR.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Compile + test runs on
  the macos-14 / macos-15 matrix.
- Manual UI verification: open menu bar, click "Pause collection… → 15 minutes",
  confirm icon flips to `pause.circle`, label reads "Paused — resumes in
  14m 58s", clicking "Resume now" clears the pause and flips the icon
  back to `waveform.path.ecg`.

## Related documents

- B2 → `B2-PROGRESS.md` (delivered `PauseController`)
- A1–A4 → `A1-PROGRESS.md` … `A4-PROGRESS.md`
- Feature spec → `02-features.md#f-46-敏感时段快捷键`
- Privacy → `docs/05-privacy.md` (pause semantics)

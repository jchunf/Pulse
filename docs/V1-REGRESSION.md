# v1.0 Regression Checklist

> Swift-level tests (PulseCore / PulseTestSupport) cover the read-side
> queries and engines. They **do not** cover what the user actually sees
> or the system integrations that only work on a real Mac. This document
> is the pre-tag manual pass before we cut `v1.0.0`.
>
> Run this on a Mac that has been using Pulse for **≥ 7 real days**
> (weekly-report and delta-vs-yesterday paths both need history).
> Check boxes as you go; file an issue per unchecked item rather than
> moving the box.

---

## 0. Preconditions

- [ ] Clean build from `main`: `swift build -c release` succeeds on
      macOS 14 and macOS 15.
- [ ] `swift test --parallel` green on both OS versions (CI already
      gates this, but re-run locally against your actual toolchain).
- [ ] Running binary has Input Monitoring + Accessibility granted, and
      `~/Library/Application Support/Pulse/pulse.sqlite` has ≥ 7 days
      of rows.
- [ ] System language toggle: verify the app follows both `en` and
      `zh-Hans` without relaunch.

## 1. Menu-bar surface

- [ ] Icon renders in light / dark menu bar.
- [ ] Anomaly red dot appears when any metric deviates ±30% from its
      7-day median (A19b). Force it by temporarily editing
      `AnomalyDetector` threshold or by picking a day whose history
      qualifies.
- [ ] Pause menu: 15 / 30 / 60 min entries each disable collection
      for the right duration and resume on their own (A5). Use the
      health panel to confirm `PauseController` state.
- [ ] "Show yesterday's briefing" item opens A18 window on demand.
- [ ] "Generate weekly report" menu item writes to
      `~/Library/Application Support/Pulse/reports/weekly-YYYY-MM-DD.html`
      and reveals it in Finder (A19).
- [ ] "Export data" writes an `ExportBundle` JSON and reveals it in
      Finder (A21). Spot-check the JSON shape against
      `Sources/PulseCore/Reports/DataExport.swift`.
- [ ] "Show what Pulse has recorded" opens A22 self-audit window and
      streams raw rows without crashing on a fresh install (empty
      tables).

## 2. Dashboard window

- [ ] Open via menu bar: first render within 2 s on an M-series Mac
      (ties back to `docs/11-ux-principles.md` 3-minute-wow budget).
- [ ] Permission banner (A8) shows only when Input Monitoring or
      Accessibility is revoked; clicking it deep-links into System
      Settings (A6).
- [ ] Top-of-dashboard goal row (A20) — set each preset, leave the day
      to accrue, verify ✅ / ❌ and the progress bar match raw query
      output.
- [ ] 6 summary cards (distance / clicks / scroll / keys / active /
      idle) each show a 7-day sparkline + delta-vs-yesterday (A17b).
      Delta colour flips at zero.
- [ ] Heatmap (A2 / A12) — switch window through 3 / 7 / 14 / 30
      days, gradient & peak-hour caption (A17a) update without a
      flicker.
- [ ] App-ranking chart (A7 / A14) uses friendly display names; a
      brand-new app not in the lookup table falls back gracefully.
- [ ] Mileage hero card (A3) shows a landmark (F-25) whenever today
      crosses a multi-landmark threshold (A17a).
- [ ] Deep-focus card (A16) — the "longest segment today" matches
      what you'd get by scanning `min_switches` manually for a known
      day.
- [ ] Session-rhythm card (A23) — posture label flips between
      Deep-worker / Steady flow / Short-form / Checker as the day
      progresses.
- [ ] Idle-time card (A15) matches `hour_summary.idle_seconds` for
      today.
- [ ] Diagnostics / health card (A11) goes green when collection is
      healthy; kick the writer (force-quit + relaunch) and confirm it
      flags the gap.

## 3. Retention hooks (the reason v1.0 exists)

- [ ] A18 daily briefing: lock screen, wait, unlock the next day.
      Briefing window appears exactly once (latch stored in
      `UserDefaults`). Copy uses NarrativeEngine framing, not raw
      numbers.
- [ ] A19b Monday auto-weekly: on the first wake of any Monday, the
      HTML weekly report is generated without user action and the
      anomaly badge clears once viewed. To exercise mid-week, clear
      the `weeklyReport.lastAutoRun` default.
- [ ] A19 weekly HTML: open in Safari + Chrome, verify charts render
      and no remote resources are requested (check Web Inspector →
      Network, should be empty — this is the privacy pitch).

## 4. Privacy pledge surfaces (review §3.7)

- [ ] `05-privacy.md` red-line list: for each item, spot-check the
      schema / code path it claims not to store.
- [ ] A22 self-audit window: confirm `events.payload` never contains
      a character or clipboard content for your last hour of use.
- [ ] `TitleHasher` — window titles in `min_app` are hashed by
      default; toggling the preference (if surfaced) shows plaintext
      only in the current session.
- [ ] Outbound network: run `lsof -i -nP | grep Pulse` while Pulse is
      live. Should be **zero** connections (update-check is not yet
      wired; confirm this stays true).

## 5. System events

- [ ] Close the lid, open it: corresponding rows appear in
      `system_events` with correct timestamps (B4).
- [ ] Unplug power on a laptop: `power_state` transitions logged.
- [ ] `caffeinate -i` for 2 min then stop: idle detection (B3 / B6)
      correctly brackets the active window.
- [ ] Multi-display: drag across two monitors, mileage accumulates
      using the normalised coordinate space (B3) — compare against a
      single-display run of similar motion.

## 6. i18n

- [ ] Switch System Settings → Language & Region to 简体中文. Every
      visible string flips; nothing falls back to `en` placeholders.
- [ ] Switch back to English mid-session. Window re-renders without
      relaunch.
- [ ] Weekly HTML report uses the locale that was active when it was
      rendered (not the current UI locale — this is intentional).

## 7. Known gaps blocking `v1.0.0` tag

These are **not** regressions; they were never implemented. Listed
here so the tag is deferred until they land (or the scope is
explicitly moved to v1.0.1).

- [ ] Review §5 立刻 #1 — `docs/06-onboarding-permissions.md` welcome
      → privacy-pledge checkbox → guided Input Monitoring prompt →
      guided Accessibility prompt. Today only the A6 recovery panel
      exists.
- [ ] Review §5 立刻 #2 — Developer ID signing, `notarytool`
      submission, Sparkle appcast. `Makefile` currently has no
      `package` / `sign` / `release` target. `docs/07-distribution.md`
      describes the intended flow.
- [ ] Update-check outbound call (needs to exist before Sparkle ships,
      and the §4 privacy audit must be updated to say "zero outbound
      except update check").

## 8. Sign-off

- [ ] All boxes in §§0–6 checked.
- [ ] §7 items either landed or explicitly deferred in a follow-up
      issue linked from `CHANGELOG.md`.
- [ ] `CHANGELOG.md` [Unreleased] heading promoted to `[1.0.0] —
      <date>`.
- [ ] `git tag -s v1.0.0` + push tag.
- [ ] Draft a GitHub Release pointing at the CHANGELOG section and
      attach the signed DMG once §7 #2 is done.

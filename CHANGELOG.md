# Changelog

All notable changes to Pulse are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Entries are grouped by release. Inside each release, changes are grouped into
**采集 / Collection (B)**, **Dashboard & 叙事 / Dashboard & Narrative (A)**,
**隐私 / Privacy**, **i18n**, and **Infrastructure**.

---

## [Unreleased] — v1.0.0-rc1 feature set

This is the first time we have a coherent "candidate" to tag. Feature scope
closes the three v1.0 goals from
`reviews/2026-04-17-product-direction.md` §2 (retention hook, narrative
engine, goals layer) and the v1.2 items from §3.5 / §3.6 / §3.7 land early.

**Gap before the v1.0 tag (see `docs/V1-REGRESSION.md`)**:

- Review §5 "立刻" #1 — full onboarding flow (welcome → privacy pledge →
  guided Input Monitoring + Accessibility prompts per `docs/06`). Today
  only the A6 `PermissionAssistantView` recovery surface exists.
- Review §5 "立刻" #2 — Developer ID signing, notarization, Sparkle
  appcast (`docs/07`). Nothing in `Makefile` / CI packages a signed
  `.app` / `.dmg` yet.

These two blockers are intentionally tracked separately so the current
feature freeze can be regression-tested on its own.

### 采集 / Collection (B)

- **B6** idle-seconds rollup — `system_events` → `min_idle` →
  `hour_summary.idle_seconds`. (#26)
- **B7** scroll-tick pipeline end-to-end, V3 migration, 6th summary
  card. (#28)
- **B8** `foregroundAppToMin` also populates
  `min_switches.app_switch_count`, unlocking cross-reference queries.
  (#29)

### Dashboard & Narrative (A)

- **A16** `NarrativeEngine` + DeepFocusCard — longest focus segment
  computed from `min_switches`, wrapped with landmark-style
  copy. Closes review §2.2. (#33)
- **A17a** multi-landmark progress panel + heatmap gradient + peak-hour
  insight. (#34)
- **A17b** summary cards gain 7-day sparkline + delta-vs-yesterday.
  (#35)
- **A18** first-wake-of-day briefing window —
  `NSWorkspace.didWakeNotification` + daily `UserDefaults` latch.
  Closes review §2.1 retention hook. (#36)
- **A19** weekly HTML report (manual trigger via menu bar). (#37)
- **A19b** auto-fire weekly report on first Monday wake + menu-bar
  anomaly badge (±30% deviation from 7-day median). (#38)
- **A20** goal / intent layer — 4 presets × `atLeast` / `atMost`,
  dashboard-top progress bars, no notification nag. Closes review
  §2.3. (#39)
- **A23** session-rhythm card — sessions / median / mean / longest +
  "Deep-worker / Steady flow / Short-form / Checker" posture label.
  Closes review §3.6. (#42)

### Privacy

- **A21** `ExportBundle` JSON export, one-click menu-bar action,
  reveals the written file in Finder. Closes review §3.5. Also clears
  remaining Swift 6 concurrency warnings. (#40)
- **A22** "Show what Pulse has recorded" self-audit window — Settings
  entry, streams raw SQLite rows + last-hour system-event ledger.
  Partial closure of review §3.7 (network-activity visualisation
  still deferred). (#41)

### i18n

- **String Catalog** (en + zh-Hans) covering every A / B surface,
  follows the system language without relaunch. Every A16–A23 PR added
  its keys alongside the feature. (#31)

### Infrastructure

- README now reflects the current slice scope instead of stalling at
  "A1–A15". (#43)
- Product-direction review captured at
  `reviews/2026-04-17-product-direction.md` (#32); this CHANGELOG
  tracks which rows are now closed.

---

## [0.x] — pre-review baseline

Everything merged before PR #32 (the product review). Summarised here
for orientation; see individual `docs/A*-PROGRESS.md` /
`docs/B*-PROGRESS.md` and PRs #1–#31 for detail.

### Collection (B1–B5)

- **B1** SPM skeleton, core protocols, V1 schema, CI. (#2)
- **B2** live collector — runtime, writer, rollup scheduler, health
  panel. (#3)
- **B3** distance accumulation, idle-tick hook, system-event emitter.
  (#8)
- **B4** IOKit lid / power observer + AX title-change observer. (#9)
- **B5** app-usage rollup pipeline (`system_events` → `min_app` →
  `hour_app`). (#15)

### Dashboard (A1–A15)

- **A1** dashboard window + app-usage ranking + read-side query
  layer. (#10) — plus fix for `todaySummary` skipping the
  `hour_summary` layer. (#16)
- **A2** 24h × 7d activity heatmap (F-03). (#12)
- **A3** mouse-mileage hero card (F-07). (#11)
- **A4** 7-day trend line (F-01 basic). (#13)
- **A5** pause controls 15 / 30 / 60 min + resume (F-46 basic). (#14)
- **A6** permission recovery assistant with deep links into System
  Settings (F-49 depth). (#17)
- **A7** app-ranking query reads `min_app` / `hour_app` with raw
  fallback. (#18)
- **A8** dashboard permission banner. (#19)
- **A9** dashboard refresh on app activation. (#20)
- **A10** Settings panel replaces placeholder (refresh frequency
  preference). (#21)
- **A11** diagnostics card surfaces F-49 on the dashboard. (#22)
- **A12** configurable heatmap window (3 / 7 / 14 / 30 days). (#23)
- **A13** milestone achievement banner (F-25). (#24)
- **A14** top-apps chart resolves friendly display names. (#25)
- **A15** dashboard shows total idle time (B6 surfacing). (#27)

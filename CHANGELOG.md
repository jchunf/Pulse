# Changelog

All notable changes to Pulse are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Entries are grouped by release. Inside each release, changes are grouped into
**采集 / Collection (B)**, **Dashboard & 叙事 / Dashboard & Narrative (A)**,
**隐私 / Privacy**, **i18n**, and **Infrastructure**.

---

## [1.0.0-rc2] — 2026-04-20

Second release candidate. Layers on top of `1.0.0-rc1` with the
cross-metric insight engine called out by review §3.4 (the last
review-flagged §3 row — review §3.4 was originally slotted for v1.2,
pulled forward), the first time-of-day insight rule, the Vital Pulse
visual-language pass, the above-the-fold Dashboard layout, and three
bug fixes surfaced by post-rc1 real-Mac dogfooding.

**Still knowingly out of scope** (carries over from rc1 §7):
Developer ID signing + `notarytool` + Sparkle appcast
(`docs/07-distribution.md`). **Formally deferred** — no longer a
`v1.0.0` blocker. Ships as a `v1.0.1` signed-distribution patch, or
folds into `v1.1`, once the maintainer's Apple Developer enrolment
completes.

### Dashboard & Narrative (A)

- **A26** Vital Pulse visual language + Retina mileage fix. (#49)
- **A26f** Dashboard layout — above-the-fold hero row + sectioned
  scroll. (#50)
- **A26g** three real-Mac bug fixes: loginwindow focus, menu-bar red
  dot, i18n leak. (#51)

### Insights engine — review §3.4

- **A27** cross-metric insight engine with three seed rules —
  `ActivityAnomalyRule` (today vs 7-day median, ±30%),
  `DeepFocusStandoutRule` (today's longest focus ≥ 1.3× median),
  `SingleAppDominanceRule` (one app > 50% of active time). Rule
  thresholds exposed as `public let` constants per review §3.4's
  "transparent, auditable, rule-based" bar. (#52)
- **A28** `HourlyActivityAnomalyRule` — first **time-of-day** rule,
  reuses `hourlyHeatmap` output so no new DB queries. Fires on the
  completed hour with the largest magnitude deviation (≥ 50%) from
  the same-hour median baseline over prior days; emits at most one
  insight per refresh to keep the card a glance, not a list. (#53)

---

## [1.0.0-rc1] — 2026-04-17

First release-candidate tag. Feature scope closes the three v1.0 goals
from `reviews/2026-04-17-product-direction.md` §2 (retention hook,
narrative engine, goals layer); the §3.5 / §3.6 / §3.7 items
(originally tagged for v1.2) land early; and the §5 "立刻" #1
(onboarding) ships in this candidate.

**Knowingly out of scope for the v1.0.0 tag** (tracked in
`docs/V1-REGRESSION.md` §7):

- Review §5 "立刻" #2 — Developer ID signing, notarization, Sparkle
  appcast (`docs/07`). The `package` workflow currently produces an
  ad-hoc-signed `.app`, runnable on the maintainer's own Mac but not
  distributable to a third party. **Formally deferred** — no longer
  a blocker for the `v1.0.0` tag. Will land as a follow-up tag
  (`v1.0.1` signed-distribution patch, or rolled into `v1.1`) once
  the maintainer's Apple Developer enrolment completes.

### Onboarding

- **A25** first-launch onboarding window (welcome → privacy pledge →
  guided Input Monitoring + Accessibility grant → ready). Auto-fires
  the first time `Pulse.app` opens on a Mac; never reopens once
  `pulse.onboarding.completedAt` is set in `UserDefaults`. Closes
  review §5 "立刻" #1. (#45)

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
- **D1** v1 prep — `CHANGELOG.md`, `docs/V1-REGRESSION.md` 8-section
  manual checklist, `scripts/package.sh` + `apple/Info.plist` template
  for ad-hoc-signed local `.app` bundles, GitHub Actions `package`
  workflow that uploads a 14-day artifact on every PR and attaches a
  zip to the auto-generated GitHub Release on `v*` tags. (#44)

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

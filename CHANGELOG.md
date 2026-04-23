# Changelog

All notable changes to Pulse are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Entries are grouped by release. Inside each release, changes are grouped into
**采集 / Collection (B)**, **Dashboard & 叙事 / Dashboard & Narrative (A)**,
**隐私 / Privacy**, **i18n**, and **Infrastructure**.

---

## [Unreleased]

Final v1.1 slice — closes F-04 mouse trajectory visualisation, the
last remaining row in the v1.1 queue from `docs/08-roadmap.md` §四.

### Dashboard & Narrative (A)

- **A35** F-04 mouse-trails card — per-display 128×128 density
  heatmap in the Dashboard's Apps section. 7-day rolling window,
  `log1p`-normalised sage → coral ramp tied to the Vital Pulse
  palette, optional `CIGaussianBlur` for smoothness.
  `MouseTrajectoryCard` hides itself when no display has any
  activity yet; per-display tiles honor physical aspect ratio via
  the latest `display_snapshots` row.

### Data layer additions

- **A35** `EventStore.mouseDensity(endingAt:days:calendar:)` +
  `latestDisplaySnapshot(displayId:)` in
  `Sources/PulseCore/Storage/MouseTrajectoryQueries.swift`. Returns
  `[MouseDisplayHistogram]` sorted by total count, cells sorted
  `(bin_y, bin_x)` for diff-friendly tests.
- **A35** `MouseDensityRenderer` (pure `CGImage` producer, stateless,
  `Sendable`) in `Sources/PulseCore/Rendering/`. Core Graphics +
  Core Image rather than Metal — data is pre-binned in SQL, per
  refresh render is 10-40 ms per tile without the GPU.

### 采集 / Collection (B)

- **B9** `day_mouse_density` pre-aggregation table + `V4` migration.
  `rollRawToSecond` now folds rolled coordinates into a 128×128
  bin-per-(local-day, display) histogram before deleting the raw
  rows. Solves the gap where `raw_mouse_moves` was emptied every
  60 seconds and `sec_mouse` / `min_mouse` carried no coordinates —
  F-04 now has multi-day data to render. Bounded by design
  (~30 MB / display / year).

### i18n

- **A35** 5 new keys in en + zh-Hans: `Mouse trails`,
  `No mouse movement recorded yet.`, `Display %lld`,
  `Primary display`, `%@ moves · last 7 days`.

---

## [1.1.10] — 2026-04-23

Dev channel + rolling pre-releases for frictionless round-trip
testing: every `main` merge now lands in a stable-URL pre-release,
and clients that opt in via Settings pick it up through Sparkle
instead of re-downloading a DMG by hand.

### Dashboard & Narrative (A)

- **A36** Menu-bar popover CTA symmetry — shared `menuBarChip`
  modifier so "Open dashboard" and "Quit Pulse" share shape / height
  / corner radius / padding (fill colour is the only delta); the
  secondary row's 5 buttons now span the full popover width via
  `Spacer(minLength:)` instead of clustering left. Resolves the
  dark-mode visibility thread that began in #78 (#81).

### Infrastructure

- **A37** Rolling `dev-latest` GitHub pre-release on every `main`
  push. Stable download URLs at
  `releases/download/dev-latest/{Pulse.dmg,Pulse.zip}` — testers
  grab the freshest `main` without waiting on a hand-cut tag. Tag
  is deleted + recreated on each merge so assets always match
  `HEAD(main)`. CI version label for main pushes changes from
  `-ci.N+sha` to `-dev.N+sha` to visibly mark testable builds vs
  throwaway PR validation builds (#82, #83).

- **A38** Sparkle dev channel (opt-in). Settings → About gains a
  "Receive development builds" toggle; flipping it points the next
  "Check for updates…" at the dev appcast served from the
  `dev-latest` release, so every `main` merge auto-prompts a dev
  subscriber within minutes. Implementation uses two separate
  feed URLs (stable `SUFeedURL` + dev `SUDevFeedURL` in Info.plist,
  selected by `PulseUpdaterDelegate.feedURLString(for:)`) rather
  than a single appcast with `<sparkle:channel>` filter tags — the
  channel-tag approach was tried and reverted pre-v1.1.6 because
  clients without `SUAllowedChannels` silently skipped every tagged
  item (the 1.1.4→1.1.5 "you're on the latest" bug was this).
  `scripts/generate_appcast.sh` accepts `CHANNEL=stable|dev`;
  `package.yml` runs EdDSA signing on main pushes too and uploads
  `appcast.xml` into the `dev-latest` release. Default stays
  `stable` so users who never flip the toggle are unaffected (#84).

### i18n

- **A38** zh-Hans for `Receive development builds` and the toggle
  caption.

---

## [1.0.0] — 2026-04-21

First stable tag. Layers on top of `1.0.0-rc1` with the
cross-metric insight engine called out by review §3.4 (the last
review-flagged §3 row — review §3.4 was originally slotted for v1.2,
pulled forward), the first time-of-day insight rule, the Vital Pulse
visual-language pass, the above-the-fold Dashboard layout, three
bug fixes surfaced by post-rc1 real-Mac dogfooding, the full F-11
streak storyline (grid + StreakAtRisk insight), five more v1.1
Dashboard cards (F-27 MacBook lid / F-26 rest segments / F-10
day timeline / F-06 weekly PDF), the F-47 time-range purge, and
Sparkle-powered in-app updates.

**Remaining deferral** (single item):

- Developer ID signing + `notarytool`. First install on a fresh
  Mac still needs the right-click → Open → Open Gatekeeper dance
  (or `xattr -dr com.apple.quarantine`). Once Apple Developer
  enrolment completes, add `codesign` + `notarytool` steps to
  `package.yml` — subsequent stable tags pick up automatically
  and the Sparkle / appcast path stays unchanged.

  All other signing-adjacent work is **closed** in this release:
  the EdDSA-signed in-app update pipeline lands in D2 (app) + D3
  (CI). "Check for updates…" downloads a signed bundle, verifies
  the signature, replaces the `.app` in-place, and does **not**
  re-trigger Gatekeeper quarantine or TCC permission prompts —
  so after the one-time first-install friction, every
  subsequent version swaps cleanly.

### Dashboard & Narrative (A)

- **A26** Vital Pulse visual language + Retina mileage fix. (#49)
- **A26f** Dashboard layout — above-the-fold hero row + sectioned
  scroll. (#50)
- **A26g** three real-Mac bug fixes: loginwindow focus, menu-bar red
  dot, i18n leak. (#51)
- **A29b** F-11 ContinuityCard — 52-week contribution grid with
  5-step sage gradient keyed to activeHours, current / longest
  streak + qualifying-day ratio in the header, locale-aware weekday
  rows (`Calendar.firstWeekday`). (#56)
- **A30** F-27 MacBook LidCard — today's lid-open count +
  7-day sparkline; auto-hides on desktops where no lid events
  ever land. (#58)
- **A31** F-26 RestCard — walks `idle_entered` / `idle_exited`
  pairs for today; surfaces count / longest / total. Complements
  the A15 idle-time tile. (#59)
- **A32** F-10 DayTimelineCard — 24h horizontal focus band driven
  by `system_events.foreground_app`, deterministic per-bundle
  coloring from an 8-entry palette, top-3 bundle legend. Placed
  above AppRankingChart in the Apps section. (#60)
- **A34** F-06 Weekly report PDF — reuses the A19 HTML pipeline,
  renders it through `WKWebView.pdf(configuration:)` at Letter
  portrait, drops a `weekly-YYYY-MM-DD.pdf` next to the HTML
  sibling. New menu-bar link "Weekly PDF…". (#62)

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
- **A29c** `StreakAtRiskRule` — composes F-11's `ContinuityStreak`
  with the insight engine. Fires only when the user has a ≥ 7-day
  streak going into today **and** today hasn't yet cleared 4
  active hours **and** it's past 15:00 local **and** today has
  some activity (never nags a zero-hour day). Copy framed as
  "here's what saves the streak", not a guilt-trip. (#57)

### Data layer additions

- **A29** F-11 continuity data layer — `continuityStreak(endingAt:
  days:activeHoursThreshold:calendar:)` scans `hour_summary`,
  buckets by local day, emits `ContinuityDay[]` + current /
  longest / qualifying-days stats. `EventStore.streakStatistics(
  [Bool])` helper factored out so the card UI and the
  `StreakAtRiskRule` share the same math. (#55)

### Privacy

- **A33** F-47 time-range data purge — Settings → Privacy gains a
  destructive "Clear data in a time range…" sheet with two date
  pickers + two-click confirmation. `EventStore.purgeRange(start:
  end:auditedAt:)` deletes rows in every data table in the window
  (raw L0 through L3 aggregates + `system_events` +
  `display_snapshots`); `rollup_watermarks` stay untouched. Writes
  a single `data_purged` audit event at `auditedAt` so the Privacy
  window still shows evidence a purge happened without preserving
  any of the purged rows. (#61)

### Infrastructure

- **D2** in-app updater, app side — Sparkle 2.x pulled in as an
  SPM dependency on `PulseApp`. `UpdateController` wraps
  `SPUStandardUpdaterController` with runtime belt-and-braces
  (`automaticallyChecksForUpdates = false`,
  `sendsSystemProfile = false`). "Check for updates…" added to
  both the menu bar and Settings → About. Info.plist's
  `SUEnableAutomaticChecks` / `SUAllowsAutomaticUpdates` /
  `SUScheduledCheckInterval` all pinned to match the
  `docs/05-privacy.md` §七 "检查更新也是你手动触发的" promise. (#64)
- **D3** in-app updater, CI side — `package.yml` detects
  stable-final tags (`^v[0-9]+\.[0-9]+\.[0-9]+$`), fetches
  Sparkle's `sign_update` tool at job time, signs the release
  `.zip` with EdDSA (private key stored as
  `SPARKLE_ED_PRIVATE_KEY` secret), generates `appcast.xml` via
  the new `scripts/generate_appcast.sh`, and attaches it to the
  stable Release (which also flips `prerelease: false` so
  `releases/latest/download/appcast.xml` resolves). rc / beta
  tags still ship zip + sha256 as pre-release; no appcast is
  generated, so Sparkle's "latest" URL never sees them. (#65)
- **V1-REGRESSION §4 privacy row split** — baseline lsof row now
  expects zero outbound when the updater is idle, and exactly one
  `github.com` HTTPS connection when the user manually clicks
  Check for updates; `sendsSystemProfile = false` is enforced so
  no Sparkle profile params leak in the query string. (#65)

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

# A3 Progress — Mileage Drama Hero (F-07)

> Delivered under branch `claude/check-progress-XvlUY`. Second slice of the
> A-track. Builds on A1 (`A1-PROGRESS.md`).

## Scope

Surface the "核心上瘾点" from `docs/08-roadmap.md`: a hero card on the
Dashboard that turns today's raw mouse-distance number into a dramatic
line ("≈ 3.2× a marathon"). The underlying `LandmarkLibrary` and
`MileageConverter` modules ship since B1; A3 is almost entirely a View
slice — no new query types, no new platform hooks, no schema changes.

## ✅ Delivered

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | New `MileageHeroCard` view. Reads `TodaySummary.totalMouseDistanceMillimeters`, asks `LandmarkLibrary.standard.bestMatch(forMeters:)` for the comparison line, and renders both in a 52-pt monospaced numeric + secondary comparison block. Linear-gradient background in the accent colour with a rounded stroke border. Placed immediately after the Dashboard header so it's the first thing the user reads. |

### Verification

No new tests — `LandmarkLibraryTests` (B1, 6 cases) already exercise
the drama-preserving selection at tiny / pool / track / marathon /
beyond-all-landmarks inputs. `MileageConverterTests` (B1) covers the
mm math.

## 🟡 Intentionally deferred

1. **Milestone achievement toast (F-25)** — "You just crossed 1 × marathon today!" one-shot banner. Needs a lightweight `last_milestone_seen_at` per-landmark record in user defaults; out of scope for A3.
2. **Mileage history chart** — distance per day over 7 / 30 / all-time. Wants the 7-day trend infrastructure (A4 slice).
3. **Localization of `humanReadable`** — today's strings are English defaults from `LandmarkLibrary.formatMultiplier`. Localized variants land with the app-wide localization pass.
4. **User-editable landmark library** — "add your commute" / "disable Pacific / equator" preference. UX milestone.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Compile + test happens
  on the GitHub Actions macos-14 / macos-15 matrix.
- Manual UI verification: open `PulseApp`, click "Open Dashboard" from
  the menu bar, confirm the hero card shows reasonable distance + a
  landmark comparison that updates with the 5-second refresh tick.

## Related documents

- A1 → `A1-PROGRESS.md`
- B1 → `B1-PROGRESS.md` (delivered `MileageConverter`, `LandmarkLibrary`)
- Feature spec → `02-features.md#f-07-指针里程表`
- UX principles → `11-ux-principles.md` (P4 "data storytelling")
- Roadmap → `08-roadmap.md` (MVP 三件套, 核心上瘾点)

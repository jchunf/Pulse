# A2 Progress — Hourly Heatmap (F-03)

> Delivered under branch `claude/check-progress-XvlUY`. Third slice of the
> A-track. Completes the MVP 三件套 (F-02 app ranking, F-07 mileage drama,
> F-03 heatmap). Builds on A1 (`A1-PROGRESS.md`).

## Scope

Surface the 24h × 7d activity heatmap on the Dashboard. Reads directly
from the already-maintained `hour_summary` L3 table — no new rollup
work. One-hour staleness for the current in-progress hour is accepted
for now (see deferred list).

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Storage/AppUsageQueries.swift` | New `EventStore.hourlyHeatmap(endingAt:days:calendar:)` reads `hour_summary` for the `days` days ending at `endingAt`, maps `ts_hour` → `(dayOffset, hour)` via the provided `Calendar`, and emits one `HeatmapCell` per hour with non-zero activity. `dayOffset == 0` is today; `days - 1` is the oldest day. |
| `Storage/AppUsageQueries.swift` | New public `HeatmapCell` value type (dayOffset / hour / activityCount). |

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | `DashboardModel` gains `heatmapCells: [HeatmapCell]` published state; `refresh()` loads it alongside `summary`. New `WeekHourlyHeatmap` view renders a 7×24 grid (`RoundedRectangle` per cell, opacity scaled to max activity in the window), with row labels (Today / Yday / short weekday name) and sparse hour labels (0, 6, 12, 18). Tooltip on hover via `.help(…)` shows exact counts. Placed between `SummaryCardsView` and `AppRankingChart`. |

### Tests (Swift Testing, 3 new cases)

| Suite | New cases |
|---|---|
| `AppUsageQueriesTests` (extended) | 3: `heatmapMapsRows` (seeds 3 `hour_summary` rows, asserts correct dayOffset + hour mapping under UTC calendar), `heatmapExcludesZero` (zero-activity rows don't emit cells), `heatmapBoundedByDays` (data outside the 7-day window is not included) |

## 🟡 Intentionally deferred

1. **Live current-hour layer** — today the in-progress hour is invisible because it hasn't rolled into `hour_summary` yet. A follow-up can layer `min_*` + `sec_*` + raw counts for the current hour. Low urgency: the 7-day pattern is the signal, a 1-hour gap doesn't hurt.
2. **Idle-second visualization** — the heatmap currently ignores `hour_summary.idle_seconds`. A future variant could dim cells that had activity but also high idle_seconds (e.g., user was present but AFK).
3. **Customizable window (14 / 30 days)** — fixed at 7 days for MVP. User preference lives in the Settings milestone.
4. **Click-through drill-down** — tapping a cell opens "details for Tuesday 14:00". Needs the Day Detail view; follow-up.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Compile + test on the
  GitHub Actions macos-14 / macos-15 matrix.
- Manual UI verification on a real Mac with ≥ 1 full hour of rolled
  activity: open Dashboard, confirm the heatmap grid shows non-zero
  cells with reasonable intensity gradient.

## Related documents

- A1 → `A1-PROGRESS.md` · A3 → `A3-PROGRESS.md`
- Data layout → `03-data-collection.md` (L3 `hour_summary`)
- Feature spec → `02-features.md#f-03-时段热力图`
- Roadmap → `08-roadmap.md` (MVP 三件套)

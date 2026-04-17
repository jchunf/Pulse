# A4 Progress — 7-Day Trend Line (F-01 basic)

> Delivered under branch `claude/check-progress-XvlUY`. Fourth A-track
> slice. Builds on A1–A3.

## Scope

Adds the 7-day activity trend line to the Dashboard (F-01 基础版). Gives
users the "数据在积累" signal on day 2 and the "数字体重" narrative after
a week — essential for the retention goal in
`docs/08-roadmap.md#二-mvp-验证指标`.

Simple LineMark over daily `keyPresses + mouseClicks`, sourced from the
existing `hour_summary` L3 table. Zero-fills days without rolled-up
activity so the x-axis stays continuous.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Storage/AppUsageQueries.swift` | New `EventStore.dailyTrend(endingAt:days:calendar:)` returns one `DailyTrendPoint` per calendar day in the window, oldest → newest, zero-padded for days without data. Aggregates `hour_summary` rows per `calendar.startOfDay`. |
| `Storage/AppUsageQueries.swift` | New public `DailyTrendPoint` value type (day, keyPresses, mouseClicks, mouseDistanceMillimeters, derived `totalEvents`). |

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | `DashboardModel` gains `trendPoints: [DailyTrendPoint]` published state; `refresh()` loads it alongside the summary + heatmap. New `WeekTrendChart` view renders a SwiftUI Charts LineMark + PointMark over 7 days, with leading y-axis marks and short weekday labels on x. Placed between `SummaryCardsView` and `WeekHourlyHeatmap` so the flow reads: hero → snapshot → trend → pattern → apps. |

### Tests (Swift Testing, 2 new cases)

| Suite | New cases |
|---|---|
| `AppUsageQueriesTests` (extended) | 2: `trendPadsAndOrders` (asserts oldest-first ordering + zero-padding for empty days), `trendSumsHoursPerDay` (multi-hour same-day aggregation into one bucket) |

## 🟡 Intentionally deferred

1. **Multi-metric overlay** — today the trend shows total events only. A future variant can toggle between keystrokes, clicks, and distance (F-07 daily km/day drama).
2. **30-day / all-time windows** — fixed at 7 days. Lives with the Settings customization milestone.
3. **Trend baselines** — "today is 20% below your 7-day average" callouts rely on F-09 focus-ring work.
4. **Live current-day layer** — same staleness caveat as A2 heatmap: the open hour isn't counted until it rolls into `hour_summary`. Acceptable for a 7-day view.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Compile + test happens
  on GitHub Actions macos-14 / macos-15 matrix.
- Manual UI verification on a real Mac with ≥ 2 days of rolled activity
  to see the line actually move.

## Related documents

- A1 → `A1-PROGRESS.md` · A2 → `A2-PROGRESS.md` · A3 → `A3-PROGRESS.md`
- Feature spec → `02-features.md#f-01-每日趋势图`
- Data layout → `03-data-collection.md` (L3 `hour_summary`)
- Roadmap → `08-roadmap.md` (MVP 验证指标)

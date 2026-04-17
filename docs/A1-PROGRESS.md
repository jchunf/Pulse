# A1 Progress — Dashboard Foundation

> Delivered under branch `claude/check-progress-XvlUY`. First slice of the
> A-track ("MVP 串通"). Builds on the completed B-track
> (`B1`–`B4`).

## Scope

A1 stands up the **read side** of Pulse end to end: a query layer over the
L1/L2/L3 tables, a separate Dashboard window scene, and the first of the
MVP "三件套" — the **app usage ranking** (F-02 from
`docs/02-features.md`). The other two (hourly heatmap F-03, mileage table
F-07) land in A2 and A3.

This is intentionally narrow: one PR that proves the read path is
correct and the SwiftUI surface compiles + ships, without trying to
deliver every visualization at once.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Storage/AppUsageQueries.swift` | New extension on `EventStore`. Three public read APIs: `todaySummary(start:end:capUntil:)`, `appUsageRanking(start:end:capUntil:limit:)`, plus the supporting `TodaySummary` / `AppUsageRow` value types. App-usage rows are derived from `system_events.foreground_app` via a `LEAD()` interval query so the rollup pipeline doesn't have to land first. Cross-day continuity (an app active before the queried range) is honoured by prepending a synthetic switch at `start`. |
| `Storage/EventStore.swift` | Relaxed `database` access from `private` to module-internal so the new query extension can reach the GRDB queue without breaking encapsulation outside the module. |

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | New `Window("Pulse Dashboard", id: "dashboard")` scene; `DashboardModel` (ObservableObject) wraps `EventStore` and refreshes every 5s while the window is visible; `DashboardView` shows four summary cards (distance, clicks, keystrokes, active time) and a SwiftUI Charts `BarMark` ranking of the top apps. `HealthMenuView` gains an "Open Dashboard" button that calls `openWindow(id:)` + `NSApp.activate`. |

### Tests (Swift Testing, ~5 new cases)

| Suite | New cases |
|---|---|
| `AppUsageQueriesTests` (new) | 5: basic interval-derivation ranking, cross-day prior-app counts, `limit` honoured, `todaySummary` sums mouse/key/app metrics across L1+L2 tables, empty-database safety |

## 🟡 Intentionally deferred

1. **Hourly heatmap (F-03)** — A2.
2. **Mileage drama view (F-07)** — A3, including the `LandmarkComparison` storyline.
3. **7-day trend chart (F-01 base)** — A4, after the daily query pattern is locked in.
4. **App-usage rollup pipeline** — today the dashboard query derives intervals from `system_events.foreground_app` directly. A follow-up B-slice will populate `sec_activity` / `min_app` from the writer + rollup so the dashboard query is `SELECT … FROM min_app` instead of a windowed scan over `system_events`. The on-disk schema is already in place.
5. **HealthPanel deep-link** — opening the Dashboard from the menu bar exists; jumping straight to the health-detail subview (e.g., from the silent-failure warning glyph) is UX polish for after A2.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test
  happens on the GitHub Actions macos-14 / macos-15 matrix (the `Charts`
  framework requires macOS 13+; we target 14+).
- Local-developer loop unchanged: `make build && make test`.
- Manual UI verification requires running `PulseApp` on a real Mac with
  granted Input Monitoring + Accessibility, opening the menu bar and
  clicking "Open Dashboard".

## Related documents

- B1 → `B1-PROGRESS.md` · B2 → `B2-PROGRESS.md` · B3 → `B3-PROGRESS.md` · B4 → `B4-PROGRESS.md`
- Architecture reference → `04-architecture.md`
- Data layout → `03-data-collection.md`
- Roadmap → `08-roadmap.md` (MVP 三件套)
- UX principles → `11-ux-principles.md`

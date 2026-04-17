# A7 Progress — `appUsageRanking` reads the B5 rollup tables

> Delivered under branch `claude/check-progress-XvlUY`. Seventh A-track
> slice, closing the follow-up noted in `A1-PROGRESS.md` / `B5-PROGRESS.md`.

## Scope

A1 introduced `appUsageRanking` with a LEAD-over-`system_events`
interval query because `sec_activity` / `min_app` / `hour_app` had no
producer yet. B5 filled those tables. A7 points the read path at the
rolled tables and keeps `system_events` as the fallback for the tail of
the range that hasn't been rolled yet.

Net effect: for week / month ranges the query no longer scans the full
switch history — `hour_app` / `min_app` pre-aggregate it.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Storage/AppUsageQueries.swift` | `runAppUsageQuery` now layers three non-overlapping sources: (1) `hour_app` for fully-rolled hours (L3), (2) `min_app` for rolled minutes in the currently-open hour (L2), (3) a LEAD query over `system_events` starting at `max(startMs, watermarkMs)` for the still-unrolled tail, capped at `capMs`. Watermark is read from `rollup_watermarks.foreground_app_to_min`. Bundle aggregates are summed across sources in Swift, sorted descending, then truncated via `prefix(limit)`. |
| `Storage/AppUsageQueries.swift` | Extracted the LEAD path into `rawPortionSeconds(db:startMs:endMs:capMs:)` so the layered caller can reuse it; retains the `priorBundle` synthetic-switch trick so cross-range continuity stays intact. |

Fresh-install behaviour unchanged: when no rollup has run the watermark is 0, the rolled portion is skipped entirely, and the whole window resolves to the LEAD path — exactly as it did in A1.

### Tests (Swift Testing, 4 new cases)

| Suite | New cases |
|---|---|
| `AppUsageQueriesTests` (extended) | 4: `rankingReadsMinApp` (watermark covers range; min_app rows produce expected totals), `rankingReadsHourApp` (hour_app rows promoted to L3 are read directly), `rankingAvoidsDoubleCountBelowWatermark` (same data in both system_events and min_app doesn't double-count — only the rolled source wins below the watermark), `rankingLayersRolledAndRaw` (one hour of hour_app + one minute of min_app + a post-watermark raw switch sum correctly per bundle). |

All existing A1 tests (`basicRanking`, `priorAppCounts`, `limitRespected`, `summarySumsMetrics`) pass unchanged because they seed nothing into `rollup_watermarks`; the layered code falls through to the raw-only path.

## 🟡 Intentionally deferred

1. **Boundary precision at rolled-hour / rolled-minute edges** — `hour_app` rows whose hour straddles the `start` timestamp get summed wholesale. For day-aligned queries (the only caller today) `start` is midnight, so this is exact. Arbitrary windows (e.g. "last 90 minutes") would over-count the boundary hour by a few minutes. Acceptable for MVP; revisit with the configurable-window work in Settings.
2. **`foreground_app_to_min` rollup delay masking** — the rolled portion is delayed by one tick of the `foregroundAppToMinInterval` (default 300s). The raw path keeps the latest switches visible in the meantime, so the dashboard never shows an empty ranking.
3. **`sec_activity` population** — still no consumer. Skipped until per-second app analytics arrives.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test
  runs on the macos-14 / macos-15 matrix.
- Manual verification on a real Mac: use the app for a few minutes,
  wait for the 5-minute `foregroundAppToMin` tick, then spot-check the
  Dashboard's "Top apps" chart — totals should match `sqlite3`
  aggregates over `hour_app` + `min_app` + any post-watermark
  `system_events`.

## Related documents

- A1 → `A1-PROGRESS.md` (introduced the LEAD-based stopgap replaced here)
- B5 → `B5-PROGRESS.md` (shipped the producer side of the pipeline)
- Architecture reference → `04-architecture.md#4.5`
- Data layout → `03-data-collection.md`

# B5 Progress — App-Usage Rollup Pipeline

> Delivered under branch `claude/check-progress-XvlUY`. First B-track
> hygiene slice after the A-series shipped. Builds on B1–B4.

## Scope

Close a gap exposed by A1's note that "`appUsageRanking` scans
`system_events` via `LEAD()`" — fine at MVP scale, but linear in the
year's switch count. B5 adds the missing rollup pipeline that was
always in the V1 schema (`sec_activity` / `min_app` / `hour_app` tables)
but had no producer. The app-usage query itself is **not** rewritten in
this PR; B5 just fills the tables so a future PR can point reads at
`min_app` / `hour_app` instead of the windowed `system_events` scan.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Resources/Migrations/V2__app_rollup.sql` | New migration. Creates `rollup_watermarks(job, last_processed_ms)` so rollups whose source isn't deleted on promotion (today: foreground-app → min_app, because `system_events` has permanent retention) can track their high-water mark and stay idempotent under repeated ticks. |
| `Storage/Migrator.swift` | `BundledMigrations.resourceNames` gains `V2__app_rollup.sql`. |
| `Runtime/RollupScheduler.swift` | Two new `Job` cases — `foregroundAppToMin` and `minAppToHour` — plus matching `Configuration` intervals (defaults 300s / 3600s) and `LastRunStamps` fields. `foregroundAppToMin` reads switches from `system_events`, prepends a synthetic leading switch at the watermark so the active bundle at the boundary isn't dropped, attributes each interval's seconds to its containing minute buckets via the helper `addSecondsPerMinute`, UPSERTs into `min_app`, and advances the watermark. `minAppToHour` mirrors the existing `rollMinuteToHour` pattern: GROUP BY hour, UPSERT into `hour_app`, `DELETE FROM min_app` for rolled minutes. `purgeExpired` already covered `min_app`. |

### Tests (Swift Testing, 4 new cases)

| Suite | New cases |
|---|---|
| `RollupSchedulerTests` (extended) | 4: `foregroundAppToMinBasic` (switch → Safari 30s + Xcode 30s in same minute + Xcode 60s in next minute), `foregroundAppToMinIdempotent` (second tick is a no-op; totals stay at 60s, not 120), `foregroundAppToMinCarriesPriorBundle` (app active 5 min before the watermark contributes 7×60s once the clock advances), `minAppToHourPromotes` (GROUP BY hour across 4 seeded min_app rows, confirms hour_app totals and min_app is emptied). |
| `MigratorTests` (updated) | `targetVersion` now 2; `schemaAppliedInMemory` adds `rollup_watermarks` to the required-tables list; `user_version` assertion bumped to 2. |

## 🟡 Intentionally deferred

1. **Point `appUsageRanking` at `min_app` / `hour_app`** — the LEAD-based scan over `system_events` still works; swapping to the rolled-up tables is a pure refactor that needs its own tests so this PR stays focused on pipeline correctness.
2. **`todaySummary` layered query correction** — `todaySummary` currently reads `min_mouse` only for the day range, but rollups delete rolled minutes, so older hours of the same day under-count. A follow-up can mirror the "hour_summary + min_* + sec_*" layering the heatmap query needs.
3. **`sec_activity` population** — V1 schema includes it but neither the writer nor any rollup touches it today. B5 chose a shorter path (system_events → min_app) because sec_activity would add ~N-switches × avg-interval-in-seconds rows with no immediate consumer. If live sub-minute activity views become a requirement, revisit.
4. **App-usage retention tuning** — `min_app` inherits the minute-layer purge cutoff from `AggregationRules`. Long-term `hour_app` stays forever; if per-app permanent history proves too heavy for a year-old install, add an L3 retention rule.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test on
  the macos-14 / macos-15 matrix.
- Manual verification on a real Mac: run `PulseApp` with granted Input
  Monitoring + Accessibility, switch between 2–3 apps over a minute,
  wait for the next `foregroundAppToMin` tick (default 5 min cadence or
  triggered at startup) and spot-check `min_app` via `sqlite3` to see
  the per-minute attribution.

## Related documents

- A1 → `A1-PROGRESS.md` (introduced the LEAD-based stopgap this PR makes unnecessary)
- B1 → `B1-PROGRESS.md` (shipped the V1 schema including `min_app` / `hour_app`)
- Architecture reference → `04-architecture.md#4.5` (migration policy)
- Data layout → `03-data-collection.md` (retention layers)

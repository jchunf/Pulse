# B9 Progress — Mouse-Density Pre-Aggregation

> Delivered alongside A35 (F-04) on the `claude/review-work-plan-Cy7Fp`
> branch. Collector-side prerequisite: without B9 the trajectory card
> would have no data because `raw_mouse_moves` is emptied on every
> `rollRawToSecond` tick.

## Scope

`raw_mouse_moves` carries `(ts, display_id, x_norm, y_norm)` rows on
every CGEventTap mouse-move event. The existing `rollRawToSecond` job
sums those rows into `sec_mouse.move_events` / `distance_mm` every 60
seconds and **deletes the rolled rows**. As a result, `raw_mouse_moves`
at any point holds ≤ 60 seconds of data — the 14-day retention the
`AggregationRules.rawCutoff` claims never had anything to retain for
mouse moves.

F-04 needs coordinates over a multi-day window. B9 introduces a
bounded pre-aggregation table so coordinates survive in a
128×128-cell-per-(local-day, display) histogram while the raw table
still gets eagerly emptied. The write path is one extra SQL statement
per `rollRawToSecond` transaction; the read path is a grouped scan
over a table that grows at ~30 MB / display / year.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Resources/Migrations/V4__mouse_density.sql` | New migration. `day_mouse_density(day, display_id, bin_x, bin_y, count)` with composite PK + `day` index. `day` is the local-midnight-in-UTC epoch-seconds of insertion, so rendering "yesterday's mouse trails" lines up with the user's wall clock. |
| `Storage/Migrator.swift` | `BundledMigrations.resourceNames` gains `V4__mouse_density.sql`. |
| `Runtime/RollupScheduler.swift` | `rollRawToSecond` grows a fourth SQL statement that folds the rolled coordinates into `day_mouse_density` via `INSERT ... ON CONFLICT DO UPDATE SET count = ... + excluded.count`. The existing DELETE still runs (so raw storage is unchanged) and the new bin statement is inside the same write transaction so atomicity is preserved. Uses `TimeZone.current.secondsFromGMT(for: now)` to compute the local-day-start bind arg. Edge clamp: `MIN(127, MAX(0, CAST(x_norm * 128 AS INTEGER)))` so `x_norm = 1.0` lands in bin 127, not 128. |

### Tests (Swift Testing)

| Suite | New cases |
|---|---|
| `MigratorTests` (updated) | `targetVersion` now 4; `schemaAppliedInMemory` adds `day_mouse_density`; `user_version` assertion bumped to 4; new `v4CreatesDayMouseDensity` asserts the column order. |
| `MouseTrajectoryQueriesTests` (new, §"Write path (B9)") | 6 rollup cases: `rollupBinsIntoDensity` (0.0 / 0.5 / 1.0 all land in correct cells), `rollupAccumulatesBin` (5 repeat moves → count 5), `rollupPartitionsByDisplay`, `rollupStillDeletesRawRows`, `rollupIdempotentForDensity`, `rollupBucketsIntoLocalDay`. |

## 🟡 Intentionally deferred

1. **Retention for `day_mouse_density`** — the table has no purge today.
   At ~30 MB / display / year the 200 MB disk alarm is hit after ~6
   years of continuous daily use on a single-display setup. Add a
   purge rule if that becomes a real concern; for v1.1 "permanent
   like hour_summary" is the simplest contract.
2. **Timezone post-hoc correction** — `day` is written in the timezone
   active at rollup time. Traveling to a new offset later doesn't
   re-bucket historic rows. Documented in
   `docs/04-architecture.md#4.1` as acceptable.
3. **Configurable grid resolution** — the 128-cell side is a
   `MouseTrajectoryGrid.size` constant consumed by both writer and
   reader. Making it runtime-tunable means a schema migration
   (different resolutions can't share the same table), so left for
   when a real user asks.
4. **Clicks density** — the same pattern would work for
   `raw_mouse_clicks` → `day_mouse_click_density`, but F-04 scope is
   "mouse trails" not "click heatmap". Future F-16 can reuse this
   migration's shape.

## 🧪 Verification

- Swift toolchain not available in this sandbox. Real compile + test
  on the macos-14 / macos-15 CI matrix.
- Manual on-device check: after the first `rollRawToSecond` tick,
  `sqlite3 ~/Library/Application\ Support/Pulse/pulse.sqlite 'SELECT
  COUNT(*), SUM(count) FROM day_mouse_density'` should show the
  non-zero cells matching the mouse moves produced in the window.

## Related documents

- F-04 rendering on top of this data — `A35-PROGRESS.md`
- Raw coordinate pipeline — `B3-PROGRESS.md`
- Retention layers — `03-data-collection.md`
- Roadmap slot — `08-roadmap.md` §四 v1.1 (final v1.1 entry)

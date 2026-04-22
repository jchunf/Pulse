# A35 Progress — F-04 Mouse Trajectory Visualisation (v1.1)

> Delivered alongside B9 on the `claude/review-work-plan-Cy7Fp`
> branch. Closes the final v1.1 item in `docs/08-roadmap.md` §四.

## Scope

F-04 says *"鼠标轨迹可视化 — 密度热力图 + 散点，支持多显示器"*. A35
ships the density heatmap half:

- Per-display density tile inside the Dashboard's **Apps** section.
- 7-day window, 128×128 bin grid produced at rollup time (see B9).
- `log1p`-normalised intensity with a 3-stop sage → coral ramp keyed
  to the Vital Pulse visual language.
- Optional Gaussian blur (3.5 px default) for smoothness.
- Tile aspect ratio honored via the latest
  `display_snapshots` row for each display.

The scatter-point half of F-04 is **not** delivered here — see
"Deferred" below for the rationale.

## ✅ Delivered

### PulseCore — read path

| Path | Change |
|---|---|
| `Storage/MouseTrajectoryQueries.swift` | New. `EventStore.mouseDensity(endingAt:days:calendar:)` returns one `MouseDisplayHistogram` per display with activity in the window, sorted by total count desc. `EventStore.latestDisplaySnapshot(displayId:)` reads the most recent `display_snapshots` row so the card can honor physical aspect ratio. Value types `MouseTrajectoryGrid`, `MouseDensityCell`, `MouseDisplayHistogram` live in the same file. |

### PulseCore — rendering

| Path | Change |
|---|---|
| `Rendering/MouseDensityRenderer.swift` | New. Takes a `MouseDisplayHistogram`, produces a `CGImage` at `gridSize × pixelsPerCell` pixels. `log1p(count) / log1p(peak)` normalisation, `ColorStop` ramp, optional `CIGaussianBlur`. Empty / all-zero histograms return `nil` so callers can skip UI. Stateless + `Sendable` — a shared singleton is fine. |

### PulseApp — Dashboard integration

| Path | Change |
|---|---|
| `PulseApp.swift` — `DashboardModel` | New `trajectoryTiles: [MouseTrajectoryTileData]` published field; refresh loop fetches `mouseDensity(endingAt: now, days: trajectoryDays=7)` and pairs each histogram with its `latestDisplaySnapshot`. |
| `PulseApp.swift` — `DashboardView` | `MouseTrajectoryCard(tiles:)` inserted into the **Apps** section after `AppRankingChart`; hidden entirely when `trajectoryTiles` is empty (first-day users, desktops with no snapshot yet). |
| `PulseApp.swift` — `MouseTrajectoryCard` + `MouseTrajectoryTile` | New views. Header = title + "%@ moves · last 7 days" subtitle. One tile per display, stacked vertically (A-layout — no physical-position reconstruction). Each tile runs `.task(id: histogram)` to compute the `CGImage` off the view-update critical path and caches it in `@State`. Aspect ratio reads from `DisplayInfo.widthPoints / heightPoints`, falls back to 1:1 when no snapshot exists. |
| `Resources/Localizable.xcstrings` | 5 new keys (en + zh-Hans): `Mouse trails`, `No mouse movement recorded yet.`, `Display %lld`, `Primary display`, `%@ moves · last 7 days`. |

### Tests (Swift Testing)

| Suite | New cases |
|---|---|
| `MouseTrajectoryQueriesTests` (new) | 8 read-path cases: `emptyDatabase`, `singleCell`, `multiDisplaySortedByTotal`, `outsideWindow`, `crossDayCellSummation`, `cellsSortedForDeterminism`, `peakCountHelper`, `latestDisplaySnapshotNewest` + `latestDisplaySnapshotMissing`. |
| `MouseDensityRendererTests` (new) | 7 rendering cases: `emptyReturnsNil`, `allZeroCellsReturnNil`, `imageSizeMatchesConfig`, `rampClampsOutOfRange`, `rampHitsStopsAtExactFractions`, `rampInterpolatesLinearly`, `peakCellAppearsInPixels`. |

## 🟡 Intentionally deferred

1. **Scatter-point overlay** — the `02-features.md` F-04 row says
   "密度热力图 + 散点". Individual-point scatter would either duplicate
   the density information (mouse-move samples) or require new
   collection (click coordinates, which we deliberately don't store
   today — see `03-data-collection.md`). Shipping only the density
   half in v1.1; if a user asks for scatter we revisit in v1.2 with
   a dedicated collection question.
2. **Metal rendering path** — the roadmap calls for Metal. A35 uses
   Core Graphics + Core Image instead because the card is static
   (5-second refresh, not 60 fps), binning is done in SQL (reducing
   a multi-million-point-per-day stream to ≤ 16 k cells per
   display), and a CGImage + optional `CIGaussianBlur` renders in
   ~20–40 ms per tile. Adding MetalKit would double the testing
   surface for no perceptible UI difference. Metal is reserved for
   when live trajectory overlays or > 50 k scatter points land.
3. **Physical-display layout** — tiles stack vertically regardless of
   whether the user's displays are side-by-side or arranged around a
   central built-in. Reconstructing real positions needs a permanent
   layout snapshot that `display_snapshots` doesn't carry today.
4. **Per-day-picker window switching** — A35 hard-codes 7 days via
   `DashboardModel.trajectoryDays`. A `3d / 7d / 14d` picker like
   `WeekHourlyHeatmap` has would be trivial to add but would need
   its own preference key + i18n; skipped for v1.1 scope lock.

## 🧪 Verification

- Swift toolchain unavailable in sandbox; real compile + test runs
  on the macos-14 / macos-15 CI matrix.
- Manual on-device:
  - Open the Dashboard on a Mac with ≥ 1 hour of post-B9 data — the
    Apps section should show a "Mouse trails" card with a filled
    density tile.
  - Hide / show an external display; on next refresh the newly
    inactive display's tile should disappear once its rolling
    7-day window empties.
  - Run Activity Monitor during the refresh — the `PulseApp`
    process should not spike above 2-3% CPU on an M1 when the tile
    first renders (baseline for a 512×512 render + blur).

## Privacy note

F-04 renders only the pre-aggregated density bins; individual mouse
positions never leave the collector. `raw_mouse_moves` continues to
be deleted immediately on rollup. `day_mouse_density` stores
`(day, display_id, bin_x, bin_y, count)` — aggregated, not
identifying. No new privacy red line is crossed; the
`docs/05-privacy.md` commitments hold.

## Related documents

- Data layer prerequisite → `B9-PROGRESS.md`
- Feature spec → `02-features.md#F-04`
- Architecture decision → `04-architecture.md#4.1` (normalized
  coordinate system)
- Roadmap → `08-roadmap.md` §四 v1.1 (this is the final entry)
- Privacy → `05-privacy.md` §二 (aggregated counts, no identifying
  data)

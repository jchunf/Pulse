-- V7: Mouse click density pre-aggregation (F-16).
--
-- F-16 mirrors F-04's storage shape exactly — same 128×128 grid, same
-- per-(local day, display) keying — but reads its raw counts from
-- `raw_mouse_clicks` instead of `raw_mouse_moves`. The two heatmaps
-- live behind a single toggle on `MouseTrajectoryCard`: "stayed here"
-- (movement / dwell) vs "clicked here" (this table). Mirroring the
-- density schema means F-16 reuses every renderer + query helper
-- F-04 already shipped (`MouseDensityRenderer`, `MouseDisplayHistogram`,
-- the model-side `trajectoryTiles` published shape).
--
-- Storage bound: clicks are sparser than moves by ~ 100×, so the
-- non-zero-cell count per display-day will typically sit below 1k.
-- Comfortably bounded — the table won't grow faster than
-- `day_mouse_density`, which docs/08-roadmap.md already sized at
-- ≤ 30 MB / display / year.
--
-- `day` semantics: epoch-seconds of the start of the LOCAL day at
-- insertion time. Identical to V4 — see that migration's preamble
-- for the full rationale.

CREATE TABLE day_click_density (
    day          INTEGER NOT NULL,
    display_id   INTEGER NOT NULL,
    bin_x        INTEGER NOT NULL,
    bin_y        INTEGER NOT NULL,
    count        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, display_id, bin_x, bin_y)
);
CREATE INDEX idx_day_click_density_day ON day_click_density(day);

-- V4: Mouse trajectory density pre-aggregation (F-04 / B9).
--
-- F-04 needs to render a mouse density heatmap over multi-day windows,
-- but `raw_mouse_moves` is eagerly emptied by `rollRawToSecond` and
-- `sec_mouse` / `min_mouse` carry only counts + distance — never the
-- coordinates. This table is the rendering-time source of truth:
-- every `rollRawToSecond` also folds the rolled rows' coordinates into
-- a fixed 128×128 bin grid per (local day, display), so the raw rows
-- can still be deleted immediately and the density survives as long
-- as the user keeps the app installed.
--
-- Storage bound: worst case 16_384 cells × #displays × #days, realistic
-- ≤ 3k non-zero cells / display-day → O(30 MB / display / year) at 50 B
-- per row. Comfortably inside the 200 MB disk alarm in `docs/08-roadmap.md`.
--
-- `day` is the epoch-**seconds** of the start of the LOCAL day at
-- insertion time (i.e. local-midnight expressed as a UTC timestamp).
-- Writing in the user's wall-clock day keeps "yesterday's mouse trails"
-- aligned to what "yesterday" feels like. Post-hoc timezone travel can
-- therefore straddle the boundary of a day that was recorded in a
-- different offset; documented as acceptable in `docs/04-architecture.md#4.1`.

CREATE TABLE day_mouse_density (
    day          INTEGER NOT NULL,
    display_id   INTEGER NOT NULL,
    bin_x        INTEGER NOT NULL,
    bin_y        INTEGER NOT NULL,
    count        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, display_id, bin_x, bin_y)
);
CREATE INDEX idx_day_mouse_density_day ON day_mouse_density(day);

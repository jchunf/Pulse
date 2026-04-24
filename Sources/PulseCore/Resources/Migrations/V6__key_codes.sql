-- V6: D-K2 keycode distribution table for F-08 ("键盘热力图").
--
-- Per Q-06 (docs/09-open-questions.md), keycode capture is opt-in:
-- the runtime writes into this table only after the user flips the
-- "Enable keyboard heatmap" toggle. The EventTap continues to emit a
-- `keyCode: nil` keyPress when capture is off, so nothing lands here.
--
-- Granularity choice: one row per (local-day, key_code) instead of
-- the sec / min / hour triplet the other keyboard tables use. The
-- heatmap reads aggregated counts over multi-day windows, so
-- sub-day resolution buys nothing, and the table stays ≤ 365 rows
-- per year per key — ≤ 40 keys typical, comfortable < 15k rows/yr.
-- Permanent retention; tiny footprint.
--
-- `day` is local-midnight-in-UTC-seconds, same convention as
-- V4's `day_mouse_density.day`. Keeps the `localOffsetSeconds`
-- folding logic consistent across both daily tables.

CREATE TABLE day_key_codes (
    day       INTEGER NOT NULL,    -- local-midnight-in-UTC-seconds
    key_code  INTEGER NOT NULL,    -- macOS virtual keycode
    count     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, key_code)
);
CREATE INDEX idx_day_key_codes_day ON day_key_codes(day);

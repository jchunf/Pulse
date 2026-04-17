-- V3: Promote scroll-tick counts into the L3 summary layer.
--
-- V1 already tracks `scroll_ticks` in `sec_mouse` and `min_mouse`, and
-- the existing `rollSecondToMinute` SQL already sums sec → min. But
-- `hour_summary` was never given a column, so minute-level scroll
-- counts were discarded when `rollMinuteToHour` pruned `min_mouse`.
--
-- Add `scroll_ticks` here so B7 can fully populate the pipeline — and
-- so `todaySummary` can layer L3 + L2 + L1 for scrolls the same way
-- it does for distance, clicks, keystrokes, and (post-B6) idle.

ALTER TABLE hour_summary ADD COLUMN scroll_ticks INTEGER NOT NULL DEFAULT 0;

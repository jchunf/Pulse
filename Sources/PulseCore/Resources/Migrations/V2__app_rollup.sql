-- V2: Rollup watermark tracking.
--
-- Required for rollup jobs whose source table is not deleted after
-- promotion. Today that's the foreground-app → min_app rollup, which
-- reads from `system_events` (permanent retention by design). Without a
-- watermark the rollup would re-process the same switches every tick and
-- double-count through UPSERT-ADD semantics.
--
-- The `job` column holds a stable string identifier; `last_processed_ms`
-- is an exclusive upper bound — on the next run, rows with
-- `ts >= last_processed_ms AND ts < new_cutoff` are processed.

CREATE TABLE rollup_watermarks (
    job               TEXT    PRIMARY KEY,
    last_processed_ms INTEGER NOT NULL
);

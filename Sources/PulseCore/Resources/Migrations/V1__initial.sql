-- Pulse V1 schema.
--
-- Layered by retention strategy (see docs/03-data-collection.md#二):
--   L0 — raw events (7–14 days)
--   L1 — per-second aggregates (30 days)
--   L2 — per-minute aggregates (1 year)
--   L3 — per-hour aggregates (permanent)
-- Plus system events (permanent) and display snapshots (permanent).
--
-- All timestamps are Unix epoch milliseconds (INTEGER, 64-bit signed).
-- All coordinates are normalized doubles in [0, 1]; pixel reconstruction
-- uses the display_snapshots table at the appropriate instant.
--
-- PRAGMA settings are applied by the Migrator before executing this file.

-- ===========================================================================
-- L0 raw event streams (short retention)
-- ===========================================================================

CREATE TABLE raw_mouse_moves (
    ts           INTEGER NOT NULL,
    display_id   INTEGER NOT NULL,
    x_norm       REAL    NOT NULL,
    y_norm       REAL    NOT NULL
);
CREATE INDEX idx_raw_mouse_moves_ts ON raw_mouse_moves(ts);

CREATE TABLE raw_mouse_clicks (
    ts             INTEGER NOT NULL,
    display_id     INTEGER NOT NULL,
    x_norm         REAL    NOT NULL,
    y_norm         REAL    NOT NULL,
    button         TEXT    NOT NULL CHECK (button IN ('left', 'right', 'middle', 'other')),
    is_double      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_raw_mouse_clicks_ts ON raw_mouse_clicks(ts);

CREATE TABLE raw_key_events (
    ts           INTEGER NOT NULL,
    key_code     INTEGER
);
CREATE INDEX idx_raw_key_events_ts ON raw_key_events(ts);

-- ===========================================================================
-- L1 per-second aggregates
-- ===========================================================================

CREATE TABLE sec_mouse (
    ts_second        INTEGER PRIMARY KEY,
    move_events      INTEGER NOT NULL DEFAULT 0,
    click_events     INTEGER NOT NULL DEFAULT 0,
    scroll_ticks     INTEGER NOT NULL DEFAULT 0,
    distance_mm      REAL    NOT NULL DEFAULT 0.0
);

CREATE TABLE sec_key (
    ts_second        INTEGER PRIMARY KEY,
    press_count      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sec_activity (
    ts_second        INTEGER PRIMARY KEY,
    bundle_id        TEXT    NOT NULL,
    is_idle          INTEGER NOT NULL DEFAULT 0
);

-- ===========================================================================
-- L2 per-minute aggregates
-- ===========================================================================

CREATE TABLE min_app (
    ts_minute    INTEGER NOT NULL,
    bundle_id    TEXT    NOT NULL,
    seconds_used INTEGER NOT NULL,
    PRIMARY KEY (ts_minute, bundle_id)
);

CREATE TABLE min_mouse (
    ts_minute        INTEGER PRIMARY KEY,
    move_events      INTEGER NOT NULL DEFAULT 0,
    click_events     INTEGER NOT NULL DEFAULT 0,
    scroll_ticks     INTEGER NOT NULL DEFAULT 0,
    distance_mm      REAL    NOT NULL DEFAULT 0.0
);

CREATE TABLE min_key (
    ts_minute        INTEGER PRIMARY KEY,
    press_count      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE min_switches (
    ts_minute          INTEGER PRIMARY KEY,
    app_switch_count   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE min_idle (
    ts_minute      INTEGER PRIMARY KEY,
    idle_seconds   INTEGER NOT NULL DEFAULT 0
);

-- ===========================================================================
-- L3 per-hour aggregates (permanent)
-- ===========================================================================

CREATE TABLE hour_app (
    ts_hour     INTEGER NOT NULL,
    bundle_id   TEXT    NOT NULL,
    seconds_used INTEGER NOT NULL,
    PRIMARY KEY (ts_hour, bundle_id)
);

CREATE TABLE hour_summary (
    ts_hour           INTEGER PRIMARY KEY,
    key_press_total   INTEGER NOT NULL DEFAULT 0,
    mouse_distance_mm REAL    NOT NULL DEFAULT 0.0,
    mouse_click_total INTEGER NOT NULL DEFAULT 0,
    idle_seconds      INTEGER NOT NULL DEFAULT 0
);

-- ===========================================================================
-- System / environmental events (permanent)
-- ===========================================================================

CREATE TABLE system_events (
    ts         INTEGER NOT NULL,
    category   TEXT    NOT NULL,
    payload    TEXT
);
CREATE INDEX idx_system_events_ts ON system_events(ts);
CREATE INDEX idx_system_events_category ON system_events(category);

-- ===========================================================================
-- Display snapshots (permanent)
-- ===========================================================================

CREATE TABLE display_snapshots (
    ts            INTEGER NOT NULL,
    display_id    INTEGER NOT NULL,
    width_px      INTEGER NOT NULL,
    height_px     INTEGER NOT NULL,
    dpi           REAL    NOT NULL,
    is_primary    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ts, display_id)
);

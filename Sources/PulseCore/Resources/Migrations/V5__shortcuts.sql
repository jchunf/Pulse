-- V5: D-K3 shortcut-count tables.
--
-- F-33 ("快捷键使用榜") needs per-combo counts at the same L1 / L2 /
-- L3 cadence as the other keyboard metrics, but sliced by combo
-- string ("cmd+c", "cmd+shift+4", "ctrl+opt+f", …). Canonicalisation
-- happens in PulseCore (`ShortcutCombo.canonical(...)`) so every
-- producer emits a stable string.
--
-- Why a separate table instead of stuffing counts into sec_key: the
-- existing `sec_key` row is a per-second total; a compound PK on
-- (ts_second, combo) keeps it sparse (no row written when no
-- shortcut fires that second) and lets `ORDER BY count DESC` return
-- a top-N trivially.
--
-- Retention matches the pattern used for sec_mouse / sec_key:
--   sec_shortcuts  — 30 days via `purge_expired`
--   min_shortcuts  — 1 year
--   hour_shortcuts — permanent

CREATE TABLE sec_shortcuts (
    ts_second INTEGER NOT NULL,
    combo     TEXT    NOT NULL,
    count     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ts_second, combo)
);
CREATE INDEX idx_sec_shortcuts_combo ON sec_shortcuts(combo);

CREATE TABLE min_shortcuts (
    ts_minute INTEGER NOT NULL,
    combo     TEXT    NOT NULL,
    count     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ts_minute, combo)
);
CREATE INDEX idx_min_shortcuts_combo ON min_shortcuts(combo);

CREATE TABLE hour_shortcuts (
    ts_hour INTEGER NOT NULL,
    combo   TEXT    NOT NULL,
    count   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (ts_hour, combo)
);
CREATE INDEX idx_hour_shortcuts_combo ON hour_shortcuts(combo);

-- ============================================================
-- Elevator Monitoring – DB Schema (PostgreSQL + TimescaleDB)
-- Phase 1: CSV Import | Phase 2: API Polling
-- ============================================================

-- TimescaleDB Extension aktivieren
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ------------------------------------------------------------
-- Aufzüge / Elevators (Stammdaten)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevators (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,       -- z.B. "Aufzug links L-Bau"
    location    TEXT,                       -- z.B. "L-Bau", "Campus HN"
    max_floor   INTEGER NOT NULL DEFAULT 10
);

-- Stammdaten einfügen
INSERT INTO elevators (name, location, max_floor) VALUES
    ('Aufzug links L-Bau',       'L-Bau',      10),
    ('Aufzug rechts L-Bau',      'L-Bau',      10),
    ('Campus Brücken HN West',   'Campus HN',   1),
    ('Feuerwehraufzug L-Bau',    'L-Bau',      10)
ON CONFLICT (name) DO NOTHING;

-- ------------------------------------------------------------
-- Fahrtenereignisse (Zeitreihentabelle)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevator_events (
    time            TIMESTAMPTZ     NOT NULL,
    elevator_id     INTEGER         NOT NULL REFERENCES elevators(id),
    floor           SMALLINT        NOT NULL,
    source          TEXT            NOT NULL DEFAULT 'csv'  -- 'csv' | 'api'
);

-- TimescaleDB Hypertable (partitioniert nach Zeit, 1 Woche pro Chunk)
SELECT create_hypertable(
    'elevator_events',
    'time',
    chunk_time_interval => INTERVAL '1 week',
    if_not_exists => TRUE
);

-- Indizes für häufige Abfragen
CREATE INDEX IF NOT EXISTS idx_events_elevator_time
    ON elevator_events (elevator_id, time DESC);

CREATE INDEX IF NOT EXISTS idx_events_floor
    ON elevator_events (floor);

-- ------------------------------------------------------------
-- Nützliche Views für Grafana
-- ------------------------------------------------------------

-- Letztes bekanntes Stockwerk pro Aufzug (Live-Status)
CREATE OR REPLACE VIEW v_current_floor AS
SELECT DISTINCT ON (elevator_id)
    e.name          AS elevator_name,
    e.location,
    ev.floor        AS current_floor,
    ev.time         AS last_seen
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
ORDER BY elevator_id, time DESC;

-- Fahrten pro Stunde (für Heatmap)
CREATE OR REPLACE VIEW v_trips_per_hour AS
SELECT
    elevator_id,
    e.name          AS elevator_name,
    date_trunc('hour', time) AS hour,
    COUNT(*)        AS trip_count
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY elevator_id, e.name, hour
ORDER BY hour;

-- Beliebteste Stockwerke pro Aufzug
CREATE OR REPLACE VIEW v_floor_frequency AS
SELECT
    e.name          AS elevator_name,
    floor,
    COUNT(*)        AS visits
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, floor
ORDER BY e.name, visits DESC;

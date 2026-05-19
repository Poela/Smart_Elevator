-- ============================================================
-- Migration: Elevision API – Erweiterte Tabellen & neue Aufzüge
-- Anwenden:
--   docker exec -i elevator-monitoring-timescaledb-1 \
--     psql -U postgres -d elevator_db < migration_elevision.sql
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. Neue Aufzüge (aus poller_config.yaml)
--    Hinweis: "Campus Brücken HN West beim L Bau" wird per
--    elevator_name_override auf "Campus Brücken HN West" gemappt
--    und muss NICHT als eigener Eintrag angelegt werden.
-- ─────────────────────────────────────────────────────────────
INSERT INTO elevators (name, location, max_floor, meta) VALUES
    ('Campus Brücken HN Ost',
     'Campus HN', 1,
     '{"lat":49.1401,"lon":9.2188,"manufacturer":"Otis","model":"Gen2 Comfort","max_speed_mps":1.0}'),
    ('Teststand lipah Aufzüge Heilbronn',
     'Campus HN', 10,
     '{"lat":49.1401,"lon":9.2188,"manufacturer":"unknown"}')
ON CONFLICT (name) DO NOTHING;

-- ─────────────────────────────────────────────────────────────
-- 2. Fehler-Events  /publicapi/events/{id}/   (alle 5 min)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_errors (
    time          TIMESTAMPTZ NOT NULL,
    elevator_id   INTEGER     NOT NULL REFERENCES elevators(id),
    api_event_id  TEXT,
    event_type    TEXT,
    category      TEXT,
    floor         SMALLINT,
    pos_mm        INTEGER,
    e4_id         TEXT,
    fst_id        TEXT,
    details       JSONB NOT NULL DEFAULT '{}'
);
SELECT create_hypertable('elevator_errors','time',
    chunk_time_interval => INTERVAL '1 week', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_errors_unique
    ON elevator_errors (time, elevator_id, api_event_id);
CREATE INDEX IF NOT EXISTS idx_errors_elevator_time
    ON elevator_errors (elevator_id, time DESC);
CREATE INDEX IF NOT EXISTS idx_errors_type
    ON elevator_errors (event_type, time DESC) WHERE event_type = 'ERROR';

-- ─────────────────────────────────────────────────────────────
-- 3. Tür-Statistiken  /conditions/doors   (alle 10 min)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_door_stats (
    time                  TIMESTAMPTZ NOT NULL,
    elevator_id           INTEGER     NOT NULL REFERENCES elevators(id),
    floor                 SMALLINT,
    door                  TEXT,
    avg_opening_ms        INTEGER,
    avg_closing_ms        INTEGER,
    reversing_count       INTEGER,
    cycles_count          INTEGER,
    photocell_activations INTEGER,
    photocell_time_ms     INTEGER
);
SELECT create_hypertable('elevator_door_stats','time',
    chunk_time_interval => INTERVAL '1 week', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_door_stats_unique
    ON elevator_door_stats (time, elevator_id, door);
CREATE INDEX IF NOT EXISTS idx_door_stats_elevator_time
    ON elevator_door_stats (elevator_id, time DESC);

-- ─────────────────────────────────────────────────────────────
-- 4. Zähl-Statistiken  /statistics/count   (stündlich)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_count_stats (
    time               TIMESTAMPTZ NOT NULL,
    elevator_id        INTEGER     NOT NULL REFERENCES elevators(id),
    car_calls          INTEGER,
    landing_calls      INTEGER,
    standard_drives    INTEGER,
    park_drives        INTEGER,
    motor_start_up     INTEGER,
    motor_start_down   INTEGER,
    total_distance_mm  BIGINT,
    avg_car_calls_main REAL,
    avg_car_loading    REAL
);
SELECT create_hypertable('elevator_count_stats','time',
    chunk_time_interval => INTERVAL '1 week', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_count_stats_unique
    ON elevator_count_stats (time, elevator_id);
CREATE INDEX IF NOT EXISTS idx_count_stats_elevator_time
    ON elevator_count_stats (elevator_id, time DESC);

-- ─────────────────────────────────────────────────────────────
-- 5. Zeit-Statistiken  /statistics/time   (stündlich)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_time_stats (
    time          TIMESTAMPTZ NOT NULL,
    elevator_id   INTEGER     NOT NULL REFERENCES elevators(id),
    drive_ms      BIGINT,
    idle_ms       BIGINT,
    drive_up_ms   BIGINT,
    drive_down_ms BIGINT,
    loading_ms    BIGINT,
    light_off_ms  BIGINT,
    esm_sleep_ms  BIGINT
);
SELECT create_hypertable('elevator_time_stats','time',
    chunk_time_interval => INTERVAL '1 week', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_time_stats_unique
    ON elevator_time_stats (time, elevator_id);
CREATE INDEX IF NOT EXISTS idx_time_stats_elevator_time
    ON elevator_time_stats (elevator_id, time DESC);

-- ─────────────────────────────────────────────────────────────
-- 6. Verfügbarkeit  /overview   (minütlich)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_availability (
    time                TIMESTAMPTZ NOT NULL,
    elevator_id         INTEGER     NOT NULL REFERENCES elevators(id),
    availability_pct    REAL,
    availability_level  TEXT,
    condition           TEXT,
    operating_category  TEXT,
    online              BOOLEAN
);
SELECT create_hypertable('elevator_availability','time',
    chunk_time_interval => INTERVAL '1 week', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_availability_elevator_time
    ON elevator_availability (elevator_id, time DESC);

-- ─────────────────────────────────────────────────────────────
-- 7. Retention Policies
-- ─────────────────────────────────────────────────────────────
SELECT add_retention_policy('elevator_errors',       INTERVAL '1 year',  if_not_exists => TRUE);
SELECT add_retention_policy('elevator_door_stats',   INTERVAL '1 year',  if_not_exists => TRUE);
SELECT add_retention_policy('elevator_count_stats',  INTERVAL '2 years', if_not_exists => TRUE);
SELECT add_retention_policy('elevator_time_stats',   INTERVAL '2 years', if_not_exists => TRUE);
SELECT add_retention_policy('elevator_availability', INTERVAL '90 days', if_not_exists => TRUE);

COMMIT;

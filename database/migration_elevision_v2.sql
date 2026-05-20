-- ============================================================
-- Migration v2: Erweiterte Elevision-API-Tabellen
-- Ausführen: python -c "
--   import psycopg2, os; from dotenv import load_dotenv; load_dotenv()
--   conn = psycopg2.connect(host=os.getenv('DB_HOST'), port=os.getenv('DB_PORT'),
--     dbname=os.getenv('DB_NAME'), user=os.getenv('DB_USER'), password=os.getenv('DB_PASSWORD'))
--   conn.cursor().execute(open('migration_elevision_v2.sql').read()); conn.commit()
-- "
-- ============================================================

-- ── 1. Fehler-Ereignisse ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_errors (
    time            TIMESTAMPTZ  NOT NULL,
    elevator_id     INTEGER      NOT NULL REFERENCES elevators(id),
    api_event_id    BIGINT,
    event_type      TEXT,                     -- ERROR | EVENT
    category        TEXT,                     -- DOOR | DRIVE | SAFETY_CIRCUIT | ...
    floor           SMALLINT,
    pos_mm          INTEGER,
    e4_id           INTEGER,
    fst_id          INTEGER,
    details         JSONB        NOT NULL DEFAULT '{}'
);
SELECT create_hypertable('elevator_errors', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_errors_elevator ON elevator_errors (elevator_id, time DESC);
CREATE INDEX IF NOT EXISTS idx_errors_category ON elevator_errors (category, time DESC);

-- ── 2. Tür-Konditionsdaten ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_door_stats (
    time                 TIMESTAMPTZ NOT NULL,
    elevator_id          INTEGER     NOT NULL REFERENCES elevators(id),
    floor                SMALLINT    NOT NULL,
    door                 TEXT        NOT NULL,   -- DOOR_A | DOOR_B | DOOR_C
    avg_opening_ms       BIGINT,
    avg_closing_ms       BIGINT,
    reversing_count      BIGINT,
    cycles_count         BIGINT,
    photocell_activations INTEGER,
    photocell_time_ms    INTEGER
);
SELECT create_hypertable('elevator_door_stats', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_door_elevator ON elevator_door_stats (elevator_id, time DESC);

-- ── 3. Zähl-Statistiken ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_count_stats (
    time                      TIMESTAMPTZ NOT NULL,
    elevator_id               INTEGER     NOT NULL REFERENCES elevators(id),
    car_calls                 INTEGER,
    landing_calls             INTEGER,
    standard_drives           INTEGER,
    park_drives               INTEGER,
    motor_start_up            INTEGER,
    motor_start_down          INTEGER,
    total_distance_mm         BIGINT,
    avg_car_calls_main        INTEGER,
    avg_car_loading           BIGINT
);
SELECT create_hypertable('elevator_count_stats', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_count_elevator ON elevator_count_stats (elevator_id, time DESC);

-- ── 4. Zeit-Statistiken ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_time_stats (
    time              TIMESTAMPTZ NOT NULL,
    elevator_id       INTEGER     NOT NULL REFERENCES elevators(id),
    drive_ms          BIGINT,
    idle_ms           BIGINT,
    drive_up_ms       BIGINT,
    drive_down_ms     BIGINT,
    loading_ms        BIGINT,
    light_off_ms      BIGINT,
    esm_sleep_ms      BIGINT
);
SELECT create_hypertable('elevator_time_stats', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_time_elevator ON elevator_time_stats (elevator_id, time DESC);

-- ── 5. Verfügbarkeits-Snapshots ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_availability (
    time                TIMESTAMPTZ NOT NULL,
    elevator_id         INTEGER     NOT NULL REFERENCES elevators(id),
    availability_pct    DOUBLE PRECISION,
    availability_level  TEXT,        -- TARGET | WARNING | CRITICAL
    condition           TEXT,        -- GOOD | LOWER_WARNING | HIGHER_CRITICAL | ...
    operating_category  TEXT,        -- NORMAL | FAULT | SERVICE | FUNCTIONAL
    online              BOOLEAN
);
SELECT create_hypertable('elevator_availability', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_avail_elevator ON elevator_availability (elevator_id, time DESC);

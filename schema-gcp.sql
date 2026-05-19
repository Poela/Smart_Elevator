-- ============================================================
-- Elevator Monitoring – DB Schema (PostgreSQL 16, Cloud SQL)
-- TimescaleDB-Syntax entfernt fuer Google Cloud SQL-Kompatibilitaet.
-- Hypertables → normale Tabellen (ausreichend fuer dieses Datenvolumen)
-- Continuous Aggregates → regulaere Views mit date_trunc()
-- ============================================================

-- ------------------------------------------------------------
-- Aufzuege (Stammdaten)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevators (
    id        SERIAL PRIMARY KEY,
    name      TEXT    NOT NULL UNIQUE,
    location  TEXT,
    max_floor INTEGER NOT NULL DEFAULT 10,
    meta      JSONB   NOT NULL DEFAULT '{}'
);

INSERT INTO elevators (name, location, max_floor, meta) VALUES
    ('Aufzug links L-Bau',               'L-Bau',     10,
     '{"lat":49.1427,"lon":9.2199,"manufacturer":"Schindler","model":"3300 MRL","max_speed_mps":1.6,"commissioned_year":2018}'),
    ('Aufzug rechts L-Bau',              'L-Bau',     10,
     '{"lat":49.1427,"lon":9.2199,"manufacturer":"Schindler","model":"3300 MRL","max_speed_mps":1.6,"commissioned_year":2018}'),
    ('Campus Brücken HN West',           'Campus HN',  1,
     '{"lat":49.1401,"lon":9.2188,"manufacturer":"Otis","model":"Gen2 Comfort","max_speed_mps":1.0,"commissioned_year":2020}'),
    ('Feuerwehraufzug L-Bau',            'L-Bau',     10,
     '{"lat":49.1427,"lon":9.2199,"manufacturer":"Schindler","model":"5500","max_speed_mps":1.6,"commissioned_year":2018}'),
    ('Campus Brücken HN Ost',            'Campus HN',  1,
     '{"lat":49.1401,"lon":9.2188,"manufacturer":"Otis","model":"Gen2 Comfort","max_speed_mps":1.0,"commissioned_year":2020}'),
    ('Teststand lipah Aufzüge Heilbronn','Campus HN', 10,
     '{"lat":49.1401,"lon":9.2188,"manufacturer":"Unknown","model":"Unknown","commissioned_year":2020}')
ON CONFLICT (name) DO NOTHING;

-- ------------------------------------------------------------
-- Sensor-Registry
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sensors (
    id            SERIAL PRIMARY KEY,
    elevator_id   INTEGER NOT NULL REFERENCES elevators(id) ON DELETE CASCADE,
    type          TEXT    NOT NULL CHECK (type IN ('csv_import','rest_api','mqtt','modbus','manual')),
    name          TEXT    NOT NULL,
    endpoint      TEXT,
    meta          JSONB   NOT NULL DEFAULT '{}',
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (elevator_id, name)
);

INSERT INTO sensors (elevator_id, type, name, meta)
SELECT id, 'csv_import', 'CSV ' || name,
       jsonb_build_object('filename', name || '.csv', 'format', 'semicolon-separated')
FROM elevators
ON CONFLICT (elevator_id, name) DO NOTHING;

-- ------------------------------------------------------------
-- Fahrtenereignisse (Zeitreihentabelle)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevator_events (
    time         TIMESTAMPTZ NOT NULL,
    elevator_id  INTEGER     NOT NULL REFERENCES elevators(id),
    floor        SMALLINT    NOT NULL,
    source       TEXT        NOT NULL DEFAULT 'csv',
    sensor_id    INTEGER     REFERENCES sensors(id),
    attributes   JSONB       NOT NULL DEFAULT '{}',
    quality_flag SMALLINT    NOT NULL DEFAULT 0,
    CONSTRAINT chk_floor_range  CHECK (floor  >= 0 AND floor <= 100),
    CONSTRAINT chk_quality_flag CHECK (quality_flag BETWEEN 0 AND 3),
    CONSTRAINT chk_source_valid CHECK (source IN ('csv','api','manual','correction'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_events_unique
    ON elevator_events (time, elevator_id);
CREATE INDEX IF NOT EXISTS idx_events_elevator_time
    ON elevator_events (elevator_id, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_floor
    ON elevator_events (floor);
CREATE INDEX IF NOT EXISTS idx_events_attributes_gin
    ON elevator_events USING GIN (attributes);
CREATE INDEX IF NOT EXISTS idx_events_source
    ON elevator_events (source, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_quality_not_valid
    ON elevator_events (quality_flag, time DESC)
    WHERE quality_flag != 1;

-- ------------------------------------------------------------
-- Wetterdaten
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS weather_observations (
    time            TIMESTAMPTZ NOT NULL,
    station_id      TEXT        NOT NULL,
    temperature_min REAL,
    temperature_max REAL,
    temperature_avg REAL,
    precipitation   REAL,
    wind_speed      REAL,
    sunshine_min    INTEGER,
    icon            INTEGER,
    source          TEXT DEFAULT 'dwd_daily'
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_weather_obs_unique
    ON weather_observations (time, station_id);

CREATE TABLE IF NOT EXISTS weather_hourly (
    time          TIMESTAMPTZ NOT NULL,
    station_id    TEXT        NOT NULL,
    temperature   REAL,
    precipitation REAL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_weather_hourly_unique
    ON weather_hourly (time, station_id);

-- ------------------------------------------------------------
-- API-Tabellen
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevator_errors (
    time         TIMESTAMPTZ NOT NULL,
    elevator_id  INTEGER     NOT NULL REFERENCES elevators(id),
    api_event_id TEXT,
    event_type   TEXT,
    category     TEXT,
    floor        SMALLINT,
    pos_mm       INTEGER,
    e4_id        TEXT,
    fst_id       TEXT,
    details      JSONB NOT NULL DEFAULT '{}'
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_errors_unique
    ON elevator_errors (time, elevator_id, api_event_id);
CREATE INDEX IF NOT EXISTS idx_errors_elevator_time
    ON elevator_errors (elevator_id, time DESC);

CREATE TABLE IF NOT EXISTS elevator_availability (
    time               TIMESTAMPTZ NOT NULL,
    elevator_id        INTEGER     NOT NULL REFERENCES elevators(id),
    availability_pct   REAL,
    availability_level TEXT,
    condition          TEXT,
    operating_category TEXT,
    online             BOOLEAN
);

CREATE INDEX IF NOT EXISTS idx_availability_elevator_time
    ON elevator_availability (elevator_id, time DESC);

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

CREATE UNIQUE INDEX IF NOT EXISTS idx_count_stats_unique
    ON elevator_count_stats (time, elevator_id);

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

CREATE UNIQUE INDEX IF NOT EXISTS idx_time_stats_unique
    ON elevator_time_stats (time, elevator_id);

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

CREATE UNIQUE INDEX IF NOT EXISTS idx_door_stats_unique
    ON elevator_door_stats (time, elevator_id, door);

-- ------------------------------------------------------------
-- ML-Forecast
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevator_forecast (
    time          TIMESTAMPTZ NOT NULL,
    elevator_name TEXT        NOT NULL,
    model         TEXT        NOT NULL DEFAULT 'prophet',
    forecast_date DATE        NOT NULL,
    yhat          REAL,
    yhat_lower    REAL,
    yhat_upper    REAL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_forecast_unique
    ON elevator_forecast (time, elevator_name, model, forecast_date);

-- ------------------------------------------------------------
-- Hilfstabellen
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS elevator_corrections (
    id            SERIAL PRIMARY KEY,
    original_time TIMESTAMPTZ NOT NULL,
    elevator_id   INTEGER     NOT NULL REFERENCES elevators(id),
    old_floor     SMALLINT    NOT NULL,
    new_floor     SMALLINT    NOT NULL,
    reason        TEXT,
    corrected_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    corrected_by  TEXT        NOT NULL DEFAULT 'system'
);

CREATE TABLE IF NOT EXISTS elevator_events_dlq (
    id           SERIAL PRIMARY KEY,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload      JSONB       NOT NULL,
    error_msg    TEXT,
    retry_count  INTEGER     DEFAULT 0,
    resolved_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_dlq_unresolved
    ON elevator_events_dlq (attempted_at)
    WHERE resolved_at IS NULL;

-- ------------------------------------------------------------
-- Views (identisch mit schema.sql, kein TimescaleDB noetig)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_current_floor AS
SELECT DISTINCT ON (elevator_id)
    e.name AS elevator_name, e.location,
    ev.floor AS current_floor, ev.time AS last_seen
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
ORDER BY elevator_id, time DESC;

CREATE OR REPLACE VIEW v_trips_per_hour AS
SELECT elevator_id, e.name AS elevator_name,
    date_trunc('hour', time) AS hour, COUNT(*) AS trip_count
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY elevator_id, e.name, date_trunc('hour', time)
ORDER BY hour;

CREATE OR REPLACE VIEW v_floor_frequency AS
SELECT e.name AS elevator_name, floor, COUNT(*) AS visits
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, floor
ORDER BY e.name, visits DESC;

CREATE OR REPLACE VIEW v_api_events AS
SELECT ev.time, e.name AS elevator_name, e.location, ev.floor, ev.source
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
WHERE ev.source = 'api'
ORDER BY ev.time DESC;

CREATE OR REPLACE VIEW v_hourly_pattern AS
SELECT e.name AS elevator_name,
    EXTRACT(HOUR FROM time)::int AS hour_of_day,
    COUNT(*) AS total_events,
    ROUND(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT date_trunc('day', time)), 0), 2) AS avg_trips_per_hour
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(HOUR FROM time)::int;

CREATE OR REPLACE VIEW v_weekday_pattern AS
SELECT e.name AS elevator_name,
    EXTRACT(DOW FROM time)::int AS day_of_week,
    COUNT(*) AS total_events,
    ROUND(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT date_trunc('day', time)), 0), 2) AS avg_trips_per_day
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(DOW FROM time)::int;

CREATE OR REPLACE VIEW v_floor_by_hour AS
SELECT e.name AS elevator_name,
    EXTRACT(HOUR FROM time)::int AS hour_of_day,
    floor, COUNT(*) AS occurrences
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(HOUR FROM time)::int, floor;

CREATE OR REPLACE VIEW v_predicted_floor AS
SELECT DISTINCT ON (elevator_name, hour_of_day)
    elevator_name, hour_of_day,
    floor AS recommended_floor, occurrences,
    ROUND(100.0 * occurrences / NULLIF(SUM(occurrences) OVER (PARTITION BY elevator_name, hour_of_day), 0), 1) AS confidence_pct
FROM v_floor_by_hour
ORDER BY elevator_name, hour_of_day, occurrences DESC;

-- ev_hourly / ev_daily: regulaere Views statt TimescaleDB Continuous Aggregates
CREATE OR REPLACE VIEW ev_hourly AS
SELECT date_trunc('hour', time) AS bucket, elevator_id,
    AVG(floor)::REAL AS avg_floor, MIN(floor) AS min_floor,
    MAX(floor) AS max_floor, COUNT(*)::INTEGER AS trip_count
FROM elevator_events
GROUP BY date_trunc('hour', time), elevator_id;

CREATE OR REPLACE VIEW ev_daily AS
SELECT date_trunc('day', time) AS bucket, elevator_id,
    AVG(floor)::REAL AS avg_floor, MIN(floor) AS min_floor,
    MAX(floor) AS max_floor, COUNT(*)::INTEGER AS trip_count
FROM elevator_events
GROUP BY date_trunc('day', time), elevator_id;

CREATE OR REPLACE VIEW v_latest_forecast AS
SELECT DISTINCT ON (time, elevator_name)
    time, elevator_name, model,
    GREATEST(0, yhat) AS forecast_trips,
    GREATEST(0, yhat_lower) AS ci_lower,
    GREATEST(0, yhat_upper) AS ci_upper,
    forecast_date
FROM elevator_forecast
ORDER BY time, elevator_name, forecast_date DESC;

CREATE OR REPLACE VIEW v_elevator_weather_daily AS
WITH daily_trips AS (
    SELECT date_trunc('day', time) AS day, e.name AS elevator_name, COUNT(*) AS trip_count
    FROM elevator_events ev JOIN elevators e ON e.id = ev.elevator_id
    GROUP BY day, e.name
)
SELECT dt.day AS time, dt.elevator_name, dt.trip_count,
    wo.temperature_min, wo.temperature_max, wo.temperature_avg,
    wo.precipitation, wo.wind_speed, wo.sunshine_min
FROM daily_trips dt
JOIN weather_observations wo ON date_trunc('day', wo.time) = dt.day
ORDER BY dt.day, dt.elevator_name;

CREATE OR REPLACE VIEW v_weather_correlation AS
WITH daily_trips AS (
    SELECT date_trunc('day', time)::date AS day, e.name AS elevator_name, COUNT(*) AS trip_count
    FROM elevator_events ev JOIN elevators e ON e.id = ev.elevator_id GROUP BY day, e.name
),
daily_weather AS (
    SELECT date_trunc('day', time)::date AS day,
        AVG(temperature_avg) AS avg_temp, SUM(precipitation) AS total_precip
    FROM weather_observations GROUP BY date_trunc('day', time)::date
)
SELECT dt.elevator_name,
    ROUND(corr(dt.trip_count, dw.avg_temp)::numeric, 3) AS corr_temperature,
    ROUND(corr(dt.trip_count, dw.total_precip)::numeric, 3) AS corr_precipitation,
    COUNT(*) AS sample_days
FROM daily_trips dt JOIN daily_weather dw ON dt.day = dw.day
GROUP BY dt.elevator_name ORDER BY dt.elevator_name;

CREATE OR REPLACE VIEW v_trips_by_temp_bucket AS
WITH daily AS (
    SELECT date_trunc('day', ev.time)::date AS day, e.name AS elevator_name, COUNT(*) AS trip_count
    FROM elevator_events ev JOIN elevators e ON e.id = ev.elevator_id GROUP BY day, e.name
),
weather_day AS (
    SELECT date_trunc('day', time)::date AS day, temperature_avg FROM weather_observations
)
SELECT
    CASE
        WHEN w.temperature_avg <  0 THEN '1: unter 0 C'
        WHEN w.temperature_avg <  5 THEN '2: 0 bis 5 C'
        WHEN w.temperature_avg < 10 THEN '3: 5 bis 10 C'
        WHEN w.temperature_avg < 15 THEN '4: 10 bis 15 C'
        WHEN w.temperature_avg < 20 THEN '5: 15 bis 20 C'
        WHEN w.temperature_avg < 25 THEN '6: 20 bis 25 C'
        ELSE                             '7: ueber 25 C'
    END AS temp_bucket,
    d.elevator_name,
    ROUND(AVG(d.trip_count)::numeric, 1) AS avg_trips_per_day,
    COUNT(*) AS sample_days
FROM daily d JOIN weather_day w ON d.day = w.day
WHERE w.temperature_avg IS NOT NULL
GROUP BY temp_bucket, d.elevator_name ORDER BY temp_bucket, d.elevator_name;

CREATE OR REPLACE VIEW v_trips_by_precip_bucket AS
WITH daily AS (
    SELECT date_trunc('day', ev.time)::date AS day, e.name AS elevator_name, COUNT(*) AS trip_count
    FROM elevator_events ev JOIN elevators e ON e.id = ev.elevator_id GROUP BY day, e.name
),
weather_day AS (
    SELECT date_trunc('day', time)::date AS day, SUM(precipitation) AS precipitation
    FROM weather_observations GROUP BY date_trunc('day', time)::date
)
SELECT
    CASE
        WHEN w.precipitation = 0  THEN '1: Kein Regen (0mm)'
        WHEN w.precipitation < 1  THEN '2: Sehr leicht (<1mm)'
        WHEN w.precipitation < 5  THEN '3: Leicht (1-5mm)'
        WHEN w.precipitation < 20 THEN '4: Massig (5-20mm)'
        ELSE                           '5: Stark (>20mm)'
    END AS precip_bucket,
    d.elevator_name,
    ROUND(AVG(d.trip_count)::numeric, 1) AS avg_trips_per_day,
    COUNT(*) AS sample_days
FROM daily d JOIN weather_day w ON d.day = w.day
WHERE w.precipitation IS NOT NULL
GROUP BY precip_bucket, d.elevator_name ORDER BY precip_bucket, d.elevator_name;

CREATE OR REPLACE VIEW v_trip_anomalies AS
WITH daily AS (
    SELECT date_trunc('day', time)::date AS ds, e.name AS elevator_name, COUNT(*) AS trips
    FROM elevator_events ev JOIN elevators e ON e.id = ev.elevator_id GROUP BY ds, e.name
),
stats AS (
    SELECT elevator_name, EXTRACT(DOW FROM ds::timestamp)::int AS dow,
        AVG(trips) AS mean_trips, STDDEV(trips) AS std_trips
    FROM daily GROUP BY elevator_name, EXTRACT(DOW FROM ds::timestamp)::int
    HAVING COUNT(*) >= 3
)
SELECT d.ds::timestamptz AS time, d.elevator_name, d.trips,
    ROUND(s.mean_trips::numeric, 1) AS expected_trips,
    ROUND(((d.trips - s.mean_trips) / NULLIF(s.std_trips, 0))::numeric, 2) AS z_score,
    CASE
        WHEN ABS((d.trips - s.mean_trips) / NULLIF(s.std_trips, 0)) > 2.0 THEN 'Ausreißer'
        WHEN ABS((d.trips - s.mean_trips) / NULLIF(s.std_trips, 0)) > 1.5 THEN 'Auffällig'
        ELSE 'Normal'
    END AS anomaly_status
FROM daily d
JOIN stats s ON s.elevator_name = d.elevator_name
    AND EXTRACT(DOW FROM d.ds::timestamp)::int = s.dow
WHERE s.std_trips IS NOT NULL AND s.std_trips > 0
ORDER BY d.ds DESC, d.elevator_name;

-- Indexes fuer haeufige Abfragen
CREATE INDEX IF NOT EXISTS idx_elevators_meta_gin ON elevators USING GIN (meta);
CREATE INDEX IF NOT EXISTS idx_corrections_elevator_time
    ON elevator_corrections (elevator_id, original_time DESC);

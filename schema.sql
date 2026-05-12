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

-- Unique constraint (required for ON CONFLICT in the importers)
-- TimescaleDB hypertable unique indexes must include the partitioning column (time)
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_unique
    ON elevator_events (time, elevator_id);

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

-- Phase 2: Nur API-Ereignisse (für Live-Vergleich mit CSV-Historik)
CREATE OR REPLACE VIEW v_api_events AS
SELECT
    ev.time,
    e.name          AS elevator_name,
    e.location,
    ev.floor,
    ev.source
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
WHERE ev.source = 'api'
ORDER BY ev.time DESC;

-- ============================================================
-- Verhaltensanalyse & Prädiktive Steuerung (Phase 2 Erweiterung)
-- ============================================================

-- Durchschnittliche Fahrten pro Tagesstunde (Betätigungsmuster)
CREATE OR REPLACE VIEW v_hourly_pattern AS
SELECT
    e.name                                                          AS elevator_name,
    EXTRACT(HOUR FROM time)::int                                    AS hour_of_day,
    COUNT(*)                                                        AS total_events,
    ROUND(
        COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT date_trunc('day', time)), 0),
        2
    )                                                               AS avg_trips_per_hour
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(HOUR FROM time)::int;

-- Durchschnittliche Fahrten pro Wochentag (0=Sonntag … 6=Samstag)
CREATE OR REPLACE VIEW v_weekday_pattern AS
SELECT
    e.name                                                          AS elevator_name,
    EXTRACT(DOW FROM time)::int                                     AS day_of_week,
    COUNT(*)                                                        AS total_events,
    ROUND(
        COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT date_trunc('day', time)), 0),
        2
    )                                                               AS avg_trips_per_day
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(DOW FROM time)::int;

-- Stockwerk-Häufigkeit je Tagesstunde (Basis für Predictive Positioning)
CREATE OR REPLACE VIEW v_floor_by_hour AS
SELECT
    e.name                       AS elevator_name,
    EXTRACT(HOUR FROM time)::int AS hour_of_day,
    floor,
    COUNT(*)                     AS occurrences
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(HOUR FROM time)::int, floor;

-- Empfohlene Zielposition pro Aufzug & Stunde (Predictive Control)
-- Wählt jeweils das häufigste Stockwerk je Elevator + Stunde
CREATE OR REPLACE VIEW v_predicted_floor AS
SELECT DISTINCT ON (elevator_name, hour_of_day)
    elevator_name,
    hour_of_day,
    floor                                                           AS recommended_floor,
    occurrences,
    ROUND(
        100.0 * occurrences
        / NULLIF(SUM(occurrences) OVER (PARTITION BY elevator_name, hour_of_day), 0),
        1
    )                                                               AS confidence_pct
FROM v_floor_by_hour
ORDER BY elevator_name, hour_of_day, occurrences DESC;

-- ============================================================
-- Wetter-Integration & Korrelationsanalyse (DWD API)
-- Station: Öhringen 10729 (nächste DWD-Station zu Heilbronn)
-- ============================================================

-- Tägliche Wetterdaten (aus DWD stationOverviewExtended)
CREATE TABLE IF NOT EXISTS weather_observations (
    time            TIMESTAMPTZ NOT NULL,
    station_id      TEXT        NOT NULL,
    temperature_min REAL,           -- °C
    temperature_max REAL,           -- °C
    temperature_avg REAL,           -- °C  (Mittel aus min/max)
    precipitation   REAL,           -- mm
    wind_speed      REAL,            -- km/h
    sunshine_min    INTEGER,        -- Sonnenstunden in Minuten
    icon            INTEGER,        -- DWD Wettersymbol-Code
    source          TEXT DEFAULT 'dwd_daily'
);

SELECT create_hypertable(
    'weather_observations', 'time',
    chunk_time_interval => INTERVAL '4 weeks',
    if_not_exists => TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_weather_obs_unique
    ON weather_observations (time, station_id);

-- Stündliche Vorhersagedaten (aus forecast1)
CREATE TABLE IF NOT EXISTS weather_hourly (
    time          TIMESTAMPTZ NOT NULL,
    station_id    TEXT        NOT NULL,
    temperature   REAL,           -- °C
    precipitation REAL            -- mm
);

SELECT create_hypertable(
    'weather_hourly', 'time',
    chunk_time_interval => INTERVAL '1 week',
    if_not_exists => TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_weather_hourly_unique
    ON weather_hourly (time, station_id);

-- Dead-Letter Queue für fehlgeschlagene API-Records
CREATE TABLE IF NOT EXISTS elevator_events_dlq (
    id           SERIAL      PRIMARY KEY,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload      JSONB       NOT NULL,
    error_msg    TEXT,
    retry_count  INTEGER     DEFAULT 0,
    resolved_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_dlq_unresolved
    ON elevator_events_dlq (attempted_at)
    WHERE resolved_at IS NULL;

-- ── Korrelations-Views ────────────────────────────────────────────────────────

-- Tägliche Fahrten + Wetter (Basis für alle Korrelations-Panels)
CREATE OR REPLACE VIEW v_elevator_weather_daily AS
WITH daily_trips AS (
    SELECT
        date_trunc('day', time)  AS day,
        e.name                   AS elevator_name,
        COUNT(*)                 AS trip_count
    FROM elevator_events ev
    JOIN elevators e ON e.id = ev.elevator_id
    GROUP BY day, e.name
)
SELECT
    dt.day                  AS time,
    dt.elevator_name,
    dt.trip_count,
    wo.temperature_min,
    wo.temperature_max,
    wo.temperature_avg,
    wo.precipitation,
    wo.wind_speed,
    wo.sunshine_min
FROM daily_trips dt
JOIN weather_observations wo
    ON date_trunc('day', wo.time) = dt.day
ORDER BY dt.day, dt.elevator_name;

-- Pearson-Korrelationskoeffizienten (PostgreSQL built-in corr())
CREATE OR REPLACE VIEW v_weather_correlation AS
WITH daily_trips AS (
    SELECT
        date_trunc('day', time)::date  AS day,
        e.name                          AS elevator_name,
        COUNT(*)                        AS trip_count
    FROM elevator_events ev
    JOIN elevators e ON e.id = ev.elevator_id
    GROUP BY day, e.name
),
daily_weather AS (
    SELECT
        date_trunc('day', time)::date   AS day,
        AVG(temperature_avg)            AS avg_temp,
        AVG(temperature_max)            AS max_temp,
        SUM(precipitation)              AS total_precip
    FROM weather_observations
    GROUP BY date_trunc('day', time)::date
)
SELECT
    dt.elevator_name,
    ROUND(corr(dt.trip_count, dw.avg_temp  )::numeric, 3) AS corr_temperature,
    ROUND(corr(dt.trip_count, dw.total_precip)::numeric, 3) AS corr_precipitation,
    COUNT(*)                                               AS sample_days
FROM daily_trips dt
JOIN daily_weather dw ON dt.day = dw.day
GROUP BY dt.elevator_name
ORDER BY dt.elevator_name;

-- Ø Fahrten pro Temperaturbereich (Bucket-Analyse)
CREATE OR REPLACE VIEW v_trips_by_temp_bucket AS
WITH daily AS (
    SELECT
        date_trunc('day', ev.time)::date AS day,
        e.name                           AS elevator_name,
        COUNT(*)                         AS trip_count
    FROM elevator_events ev
    JOIN elevators e ON e.id = ev.elevator_id
    GROUP BY day, e.name
),
weather_day AS (
    SELECT date_trunc('day', time)::date AS day, temperature_avg
    FROM weather_observations
)
SELECT
    CASE
        WHEN w.temperature_avg <  0  THEN '1: unter 0 C'
        WHEN w.temperature_avg <  5  THEN '2: 0 bis 5 C'
        WHEN w.temperature_avg < 10  THEN '3: 5 bis 10 C'
        WHEN w.temperature_avg < 15  THEN '4: 10 bis 15 C'
        WHEN w.temperature_avg < 20  THEN '5: 15 bis 20 C'
        WHEN w.temperature_avg < 25  THEN '6: 20 bis 25 C'
        ELSE                              '7: ueber 25 C'
    END                                         AS temp_bucket,
    d.elevator_name,
    ROUND(AVG(d.trip_count)::numeric, 1)        AS avg_trips_per_day,
    COUNT(*)                                    AS sample_days
FROM daily d
JOIN weather_day w ON d.day = w.day
WHERE w.temperature_avg IS NOT NULL
GROUP BY temp_bucket, d.elevator_name
ORDER BY temp_bucket, d.elevator_name;

-- Ø Fahrten pro Niederschlagsstufe (Bucket-Analyse)
CREATE OR REPLACE VIEW v_trips_by_precip_bucket AS
WITH daily AS (
    SELECT
        date_trunc('day', ev.time)::date AS day,
        e.name                           AS elevator_name,
        COUNT(*)                         AS trip_count
    FROM elevator_events ev
    JOIN elevators e ON e.id = ev.elevator_id
    GROUP BY day, e.name
),
weather_day AS (
    SELECT date_trunc('day', time)::date AS day, SUM(precipitation) AS precipitation
    FROM weather_observations
    GROUP BY date_trunc('day', time)::date
)
SELECT
    CASE
        WHEN w.precipitation = 0   THEN '1: Kein Regen (0mm)'
        WHEN w.precipitation < 1   THEN '2: Sehr leicht (<1mm)'
        WHEN w.precipitation < 5   THEN '3: Leicht (1-5mm)'
        WHEN w.precipitation < 20  THEN '4: Massig (5-20mm)'
        ELSE                            '5: Stark (>20mm)'
    END                                         AS precip_bucket,
    d.elevator_name,
    ROUND(AVG(d.trip_count)::numeric, 1)        AS avg_trips_per_day,
    COUNT(*)                                    AS sample_days
FROM daily d
JOIN weather_day w ON d.day = w.day
WHERE w.precipitation IS NOT NULL
GROUP BY precip_bucket, d.elevator_name
ORDER BY precip_bucket, d.elevator_name;

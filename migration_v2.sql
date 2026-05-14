-- ============================================================
-- Migration V2 – Schema-Anforderungen (Aufgabenstellung Teil 2)
-- Idempotent: sicher auf bestehender Datenbank ausführbar
--
-- Begründung DB-Wahl PostgreSQL + TimescaleDB (vs. MongoDB):
--   • Starke JOIN-Semantik (Stamm- + Zeitreihendaten in einer Engine)
--   • time_bucket() + Continuous Aggregates ersetzen MapReduce
--   • JSONB ermöglicht flexiblen Attribut-Teil OHNE Schema-Migration
--   • Hypertables partitionieren automatisch nach Zeit (Chunk = 1 Woche)
--   • ON CONFLICT = atomares Upsert; keine Transaktion über Netzwerk nötig
--   MongoDB wäre besser bei: vollständig schemalosem Ingress,
--   horizontaler Sharding-Pflicht ab Tag 1, Document-Nesting > 3 Ebenen.
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SENSOR-REGISTRY  (Stammdaten: Trennung Thing vs. Sensor vs. Observation)
--    Orientiert an OGC SensorThings API:
--      elevators  → Things      (physisches Objekt)
--      sensors    → Sensors     (Messgerät / Datenquelle)
--      elevator_events → Observations (Einzelmessung)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sensors (
    id            SERIAL PRIMARY KEY,
    elevator_id   INTEGER NOT NULL REFERENCES elevators(id) ON DELETE CASCADE,
    type          TEXT    NOT NULL
                    CHECK (type IN ('csv_import','rest_api','mqtt','modbus','manual')),
    name          TEXT    NOT NULL,
    endpoint      TEXT,                          -- URL, MQTT-Topic, Modbus-Adresse
    meta          JSONB   NOT NULL DEFAULT '{}', -- Protokoll, Firmware, Kalibrierung …
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (elevator_id, name)
);

-- Bestehende Quellen als Sensoren registrieren
INSERT INTO sensors (elevator_id, type, name, meta)
SELECT id,
       'csv_import',
       'CSV ' || name,
       jsonb_build_object('filename', name || '.csv', 'format', 'semicolon-separated')
FROM   elevators
ON CONFLICT (elevator_id, name) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. JSONB-ATTRIBUT auf Stammdaten (elevators.meta)
--    Neue Sensor-Typen / Attribute OHNE ALTER TABLE möglich
--    Geo-Koordinaten ermöglichen GiST-Index ohne PostGIS-Extension
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE elevators
    ADD COLUMN IF NOT EXISTS meta JSONB NOT NULL DEFAULT '{}';

-- Beispiel-Befüllung (Geo + technische Stammdaten)
UPDATE elevators
SET    meta = jsonb_build_object(
           'lat', 49.1427,  'lon', 9.2199,
           'building', 'L-Bau',
           'manufacturer', 'Schindler',
           'model', '3300 MRL',
           'max_speed_mps', 1.6,
           'commissioned_year', 2018
       )
WHERE  name LIKE '%L-Bau%' AND meta = '{}';

UPDATE elevators
SET    meta = jsonb_build_object(
           'lat', 49.1401,  'lon', 9.2188,
           'building', 'Brücken-Campus',
           'manufacturer', 'Otis',
           'model', 'Gen2 Comfort',
           'max_speed_mps', 1.0,
           'commissioned_year', 2020
       )
WHERE  name LIKE '%Campus%' AND meta = '{}';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. JSONB-ATTRIBUT + QUALITÄTSFLAG auf Observations (elevator_events)
--    attributes: Late-Data, Richtung, Last-kg, Tür-Status u.a. ohne Migration
--    quality_flag:
--      0 = raw     – eingegangen, noch nicht bewertet
--      1 = valid   – alle Checks bestanden
--      2 = suspect – formal gültig, statistisch auffällig (Ausreißer, > max_floor)
--      3 = invalid – abgelehnt, zur Rückverfolgung aufbewahrt
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE elevator_events
    ADD COLUMN IF NOT EXISTS attributes   JSONB    NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS quality_flag SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS sensor_id    INTEGER  REFERENCES sensors(id);

-- Bestehende CSV-Events dem jeweiligen Sensor zuordnen
UPDATE elevator_events ee
SET    sensor_id = s.id
FROM   sensors s
WHERE  ee.elevator_id = s.elevator_id
  AND  s.type = 'csv_import'
  AND  ee.sensor_id IS NULL
  AND  ee.source = 'csv';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. DB-SEITIGE CONSTRAINTS  (Datenqualität: Validierung auf DB-Ebene)
-- ─────────────────────────────────────────────────────────────────────────────
-- Stockwerk-Bereich (physikalische Plausibilität)
ALTER TABLE elevator_events DROP CONSTRAINT IF EXISTS chk_floor_range;
ALTER TABLE elevator_events
    ADD CONSTRAINT chk_floor_range CHECK (floor >= 0 AND floor <= 100);

-- quality_flag-Wertebereich
ALTER TABLE elevator_events DROP CONSTRAINT IF EXISTS chk_quality_flag;
ALTER TABLE elevator_events
    ADD CONSTRAINT chk_quality_flag CHECK (quality_flag BETWEEN 0 AND 3);

-- Zulässige Quellen (Erweiterbar ohne Schema-Änderung via sensors.type)
ALTER TABLE elevator_events DROP CONSTRAINT IF EXISTS chk_source_valid;
ALTER TABLE elevator_events
    ADD CONSTRAINT chk_source_valid
    CHECK (source IN ('csv','api','manual','correction'));

-- Plausibilitäts-Constraint für Wetterdaten
ALTER TABLE weather_observations DROP CONSTRAINT IF EXISTS chk_temp_range;
ALTER TABLE weather_observations
    ADD CONSTRAINT chk_temp_range
    CHECK (temperature_avg IS NULL OR temperature_avg BETWEEN -50 AND 60);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. KORREKTUR-LOG (Late Data / Korrekturen / Duplikat-Strategie)
--    Verspätete Werte: TimescaleDB akzeptiert sie – ältere Chunks bleiben offen.
--    Duplikate:        ON CONFLICT DO NOTHING / DO UPDATE auf (time, elevator_id).
--    Korrekturen:      Original bleibt (Auditpfad); Korrekturevent separat geloggt.
--      Workflow: 1) Log-Eintrag hier,  2) UPDATE elevator_events SET floor=new,
--                   quality_flag=1 WHERE time=original_time AND elevator_id=x
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS elevator_corrections (
    id              SERIAL PRIMARY KEY,
    original_time   TIMESTAMPTZ  NOT NULL,
    elevator_id     INTEGER      NOT NULL REFERENCES elevators(id),
    old_floor       SMALLINT     NOT NULL,
    new_floor       SMALLINT     NOT NULL,
    reason          TEXT,
    corrected_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    corrected_by    TEXT         NOT NULL DEFAULT 'system'
);

CREATE INDEX IF NOT EXISTS idx_corrections_elevator_time
    ON elevator_corrections (elevator_id, original_time DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. INDEXIERUNGS-KONZEPT
--    Query-Pattern          Index-Typ            Spalten
--    ───────────────────────────────────────────────────────────────
--    Zeitbereich            B-Tree (Hypertable)  (elevator_id, time DESC)  ← vorhanden
--    Stockwerk-Häufigkeit   B-Tree               (floor)                   ← vorhanden
--    Geo-Nähe (JSONB lat/lon) GIN → Functional    meta->>'lat', meta->>'lon'
--    JSONB-Attribut-Suche   GIN                  (attributes), (meta)
--    Qualitäts-Filter       Partial B-Tree       (quality_flag) WHERE ≠ 1
--    Quell-Filter           B-Tree               (source, time DESC)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_events_attributes_gin
    ON elevator_events USING GIN (attributes);

CREATE INDEX IF NOT EXISTS idx_elevators_meta_gin
    ON elevators USING GIN (meta);

-- Functional Index für Geo-Queries ohne PostGIS:
--   WHERE (meta->>'lat')::float BETWEEN 49.0 AND 49.3
--     AND (meta->>'lon')::float BETWEEN 9.1  AND 9.3
CREATE INDEX IF NOT EXISTS idx_elevators_lat
    ON elevators ((  (meta->>'lat')::float  ));
CREATE INDEX IF NOT EXISTS idx_elevators_lon
    ON elevators ((  (meta->>'lon')::float  ));

-- Partial-Index: nur nicht-valide Events (häufige Monitoring-Query)
CREATE INDEX IF NOT EXISTS idx_events_quality_not_valid
    ON elevator_events (quality_flag, time DESC)
    WHERE quality_flag != 1;

CREATE INDEX IF NOT EXISTS idx_events_source
    ON elevator_events (source, time DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. CONTINUOUS AGGREGATES (Aggregations-Strategie)
--    Rohdaten     → elevator_events           (1 Jahr Retention)
--    Stundenmittel → ev_hourly               (unbegrenzt / 5 Jahre)
--    Tagesmittel   → ev_daily                (unbegrenzt)
--    timescaledb.materialized_only=false:
--      Abfragen liefern materialisierte + noch nicht materialisierte Echtzeit-Daten
-- ─────────────────────────────────────────────────────────────────────────────
CREATE MATERIALIZED VIEW IF NOT EXISTS ev_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 hour', time)  AS bucket,
    elevator_id,
    AVG(floor)::REAL             AS avg_floor,
    MIN(floor)                   AS min_floor,
    MAX(floor)                   AS max_floor,
    COUNT(*)::INTEGER            AS trip_count
FROM elevator_events
GROUP BY bucket, elevator_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('ev_hourly',
    start_offset      => INTERVAL '3 hours',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => TRUE
);

CREATE MATERIALIZED VIEW IF NOT EXISTS ev_daily
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 day', time)   AS bucket,
    elevator_id,
    AVG(floor)::REAL             AS avg_floor,
    MIN(floor)                   AS min_floor,
    MAX(floor)                   AS max_floor,
    COUNT(*)::INTEGER            AS trip_count
FROM elevator_events
GROUP BY bucket, elevator_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('ev_daily',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day',
    if_not_exists     => TRUE
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. RETENTION POLICIES
--    Rohdaten:            1 Jahr  (danach automatisches Drop via TimescaleDB)
--    Wetter (täglich):    3 Jahre (Korrelationsanalysen brauchen längere Reihen)
--    Wetter (stündlich):  90 Tage (nur für kurzfristige Forecast-Vergleiche)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT add_retention_policy('elevator_events',     INTERVAL '1 year',  if_not_exists => TRUE);
SELECT add_retention_policy('weather_observations', INTERVAL '3 years', if_not_exists => TRUE);
SELECT add_retention_policy('weather_hourly',       INTERVAL '90 days', if_not_exists => TRUE);

COMMIT;

-- Historische Daten rückwirkend in Aggregate befüllen (außerhalb Transaktion)
CALL refresh_continuous_aggregate('ev_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('ev_daily',  NULL, NULL);

-- ─────────────────────────────────────────────────────────────────────────────
-- Beispiel-Queries für die wichtigsten Zugriffspfade
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Zeitbereich-Query: Events eines Aufzugs der letzten 24 Stunden
--    → nutzt idx_events_elevator_time (elevator_id, time DESC)
/*
SELECT time, floor, quality_flag, attributes
FROM elevator_events
WHERE elevator_id = 1
  AND time >= NOW() - INTERVAL '24 hours'
  AND quality_flag IN (1, 2)
ORDER BY time DESC;
*/

-- 2. Stundenmittel aus Continuous Aggregate (Grafana Timeseries)
--    → liest ev_hourly, kein Scan der Rohdaten
/*
SELECT bucket AS time, avg_floor, trip_count
FROM ev_hourly
WHERE elevator_id = 1
  AND bucket >= $__timeFrom()::timestamptz
  AND bucket <  $__timeTo()::timestamptz
ORDER BY bucket;
*/

-- 3. Geo-Query: Aufzüge im Umkreis (ohne PostGIS, via JSONB-Functional-Index)
--    → nutzt idx_elevators_lat / idx_elevators_lon
/*
SELECT name, meta->>'building', (meta->>'lat')::float AS lat, (meta->>'lon')::float AS lon
FROM elevators
WHERE (meta->>'lat')::float BETWEEN 49.13 AND 49.16
  AND (meta->>'lon')::float BETWEEN  9.20 AND  9.23;
*/

-- 4. Sensor-ID-Query: Alle Events eines bestimmten Sensors (Qualitätsprüfung)
--    → JOIN sensors → idx_events_source
/*
SELECT ee.time, ee.floor, ee.quality_flag
FROM elevator_events ee
JOIN sensors s ON s.id = ee.sensor_id
WHERE s.type = 'csv_import'
  AND ee.quality_flag = 2          -- nur Suspect-Events
ORDER BY ee.time DESC
LIMIT 100;
*/

-- 5. JSONB-Attribut-Query: Events mit bekannter Fahrtrichtung (nach Ingest via API)
--    → nutzt idx_events_attributes_gin
/*
SELECT time, floor, attributes->>'direction' AS direction
FROM elevator_events
WHERE attributes @> '{"direction": "up"}'
  AND time >= NOW() - INTERVAL '1 hour';
*/

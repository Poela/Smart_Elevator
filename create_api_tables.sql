-- API-Tabellen für Fehler, Wartung und Türen-Dashboards

CREATE TABLE IF NOT EXISTS elevator_errors (
    time         TIMESTAMPTZ  NOT NULL,
    elevator_id  INTEGER      NOT NULL REFERENCES elevators(id),
    event_type   TEXT         NOT NULL,
    category     TEXT,
    floor        SMALLINT,
    e4_id        TEXT
);
SELECT create_hypertable('elevator_errors','time',chunk_time_interval=>INTERVAL '1 week',if_not_exists=>TRUE);
CREATE INDEX IF NOT EXISTS idx_elevator_errors_elevator_time ON elevator_errors (elevator_id, time DESC);

CREATE TABLE IF NOT EXISTS elevator_availability (
    time                TIMESTAMPTZ NOT NULL,
    elevator_id         INTEGER     NOT NULL REFERENCES elevators(id),
    availability_pct    REAL,
    operating_category  TEXT,
    online              BOOLEAN
);
SELECT create_hypertable('elevator_availability','time',chunk_time_interval=>INTERVAL '1 week',if_not_exists=>TRUE);
CREATE INDEX IF NOT EXISTS idx_elevator_avail_elevator_time ON elevator_availability (elevator_id, time DESC);

CREATE TABLE IF NOT EXISTS elevator_count_stats (
    time              TIMESTAMPTZ NOT NULL,
    elevator_id       INTEGER     NOT NULL REFERENCES elevators(id),
    motor_start_up    INTEGER,
    motor_start_down  INTEGER,
    total_distance_mm BIGINT,
    car_calls         INTEGER,
    landing_calls     INTEGER
);
SELECT create_hypertable('elevator_count_stats','time',chunk_time_interval=>INTERVAL '1 week',if_not_exists=>TRUE);
CREATE INDEX IF NOT EXISTS idx_elevator_count_elevator_time ON elevator_count_stats (elevator_id, time DESC);

CREATE TABLE IF NOT EXISTS elevator_time_stats (
    time        TIMESTAMPTZ NOT NULL,
    elevator_id INTEGER     NOT NULL REFERENCES elevators(id),
    drive_ms    BIGINT,
    idle_ms     BIGINT,
    loading_ms  BIGINT
);
SELECT create_hypertable('elevator_time_stats','time',chunk_time_interval=>INTERVAL '1 week',if_not_exists=>TRUE);
CREATE INDEX IF NOT EXISTS idx_elevator_time_elevator_time ON elevator_time_stats (elevator_id, time DESC);

CREATE TABLE IF NOT EXISTS elevator_door_stats (
    time                  TIMESTAMPTZ NOT NULL,
    elevator_id           INTEGER     NOT NULL REFERENCES elevators(id),
    door                  TEXT        NOT NULL,
    reversing_count       INTEGER,
    photocell_activations INTEGER,
    avg_opening_ms        REAL,
    avg_closing_ms        REAL,
    cycles_count          INTEGER
);
SELECT create_hypertable('elevator_door_stats','time',chunk_time_interval=>INTERVAL '1 week',if_not_exists=>TRUE);
CREATE INDEX IF NOT EXISTS idx_elevator_door_elevator_time ON elevator_door_stats (elevator_id, time DESC);

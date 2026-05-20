-- Neue Views fuer Verhaltensanalyse & Predictive Control
-- Sicher ausfuehrbar auf bestehender DB (CREATE OR REPLACE)

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

CREATE OR REPLACE VIEW v_floor_by_hour AS
SELECT
    e.name                       AS elevator_name,
    EXTRACT(HOUR FROM time)::int AS hour_of_day,
    floor,
    COUNT(*)                     AS occurrences
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, EXTRACT(HOUR FROM time)::int, floor;

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

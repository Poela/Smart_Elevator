-- ============================================================
-- Migration: Elevision-API-Controller als Aufzüge eintragen
-- Ausführen via Python (empfohlen, wegen UTF-8):
--   python migration_elevision.py
-- Oder direkt im Docker-Container:
--   docker exec -i smart_elevator-main-timescaledb-1 psql -U postgres -d elevator_db < migration_elevision.sql
-- ============================================================

INSERT INTO elevators (name, location, max_floor) VALUES
    ('Campus Brücken HN West beim L Bau', 'Campus HN', 1),
    ('Campus Brücken HN Ost',             'Campus HN', 1),
    ('Teststand lipah Aufzüge Heilbronn', 'Campus HN', 10)
ON CONFLICT (name) DO NOTHING;

"""
DWD Weather Poller – Heilbronn (Baden-Württemberg)
===================================================
Ruft Wetterdaten für Heilbronn vom Deutschen Wetterdienst ab und speichert
sie in der weather_observations-Tabelle für die Korrelationsanalyse.

Station: Öhringen (ID 10729) – nächste DWD-Messstation zu Heilbronn (~20 km)
         Alternativ: Stuttgart (10739) als Fallback

API:  https://app-prod-ws.warnwetter.de/v30/stationOverviewExtended
Doku: https://listed.to/@DieSieben/7851/api-des-deutschen-wetterdienstes

Nutzung:
    python dwd_poller.py           # Einmaliger Lauf
    python dwd_poller.py --loop    # Dauerbetrieb (stündlich, konfigurierbar)

Umgebungsvariablen (.env):
    DWD_STATION_ID          – DWD-Stationskennung  (Standard: 10729)
    DWD_POLL_INTERVAL_SEC   – Intervall in Sekunden (Standard: 3600 = 1h)
    DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD

Einheiten der DWD-API (Rohwerte, werden automatisch umgerechnet):
    temperature*   – Zehntel-Grad Celsius  → ÷ 10 → °C
    precipitation  – Zehntel-Millimeter    → ÷ 10 → mm
    windSpeed      – km/h                  (kein Faktor)
    sunshine       – Minuten               (kein Faktor)
"""

import argparse
import logging
import os
import time
from datetime import datetime, timezone

import httpx
import psycopg2
from dotenv import load_dotenv
from tenacity import (
    RetryError,
    before_sleep_log,
    retry,
    stop_after_attempt,
    wait_exponential,
)

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
log = logging.getLogger("elevator.dwd")

# ── Konfiguration ─────────────────────────────────────────────────────────────
DWD_STATION_ID    = os.getenv("DWD_STATION_ID", "10729")   # Öhringen / HN
DWD_API_URL       = "https://app-prod-ws.warnwetter.de/v30/stationOverviewExtended"
DWD_POLL_INTERVAL = int(os.getenv("DWD_POLL_INTERVAL_SEC", "3600"))

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),
}

# DWD Skalierungsfaktoren
_TEMP_SCALE   = 0.1   # Zehntel-°C → °C
_PRECIP_SCALE = 0.1   # Zehntel-mm → mm


# ── Datenbankverbindung ───────────────────────────────────────────────────────
def get_connection():
    return psycopg2.connect(**DB_CONFIG)


# ── API-Abfrage mit Retry ─────────────────────────────────────────────────────
@retry(
    stop=stop_after_attempt(5),
    wait=wait_exponential(multiplier=1, min=5, max=120),
    before_sleep=before_sleep_log(log, logging.WARNING),
    reraise=True,
)
def fetch_dwd(station_id: str) -> dict:
    """Holt rohe DWD-Daten für eine Station (mit Exponential Backoff)."""
    response = httpx.get(
        DWD_API_URL,
        params={"stationIds": station_id},
        timeout=30.0,
        headers={"Accept": "application/json"},
    )
    response.raise_for_status()
    return response.json()


# ── Parsing: Tagesdaten ───────────────────────────────────────────────────────
def parse_daily(raw: dict, station_id: str) -> list[dict]:
    """
    Parst das 'days'-Array: tägliche Aggregatwerte.
    Enthält Min-/Max-Temperatur, Niederschlag, Wind, Sonnenstunden.
    """
    station_data = raw.get(station_id) or raw.get(str(station_id), {})
    if not station_data:
        log.warning("Keine Daten für Station '%s' in der Antwort.", station_id)
        return []

    records = []
    for day in station_data.get("days", []):
        day_str = day.get("dayDate")
        if not day_str:
            continue
        try:
            ts = datetime.strptime(day_str, "%Y-%m-%d").replace(
                hour=12, tzinfo=timezone.utc  # Mittagswert als Tages-Repräsentant
            )
        except ValueError:
            log.warning("Ungültiges Datum: %s", day_str)
            continue

        t_min   = day.get("temperatureMin")
        t_max   = day.get("temperatureMax")
        precip  = day.get("precipitation")

        records.append({
            "time":            ts,
            "station_id":      station_id,
            "temperature_min": round(t_min * _TEMP_SCALE, 1)   if t_min   is not None else None,
            "temperature_max": round(t_max * _TEMP_SCALE, 1)   if t_max   is not None else None,
            "temperature_avg": round((t_min + t_max) / 2 * _TEMP_SCALE, 1)
                               if (t_min is not None and t_max is not None) else None,
            "precipitation":   round(precip * _PRECIP_SCALE, 1) if precip is not None else None,
            "wind_speed":      day.get("windSpeed"),
            "sunshine_min":    day.get("sunshine"),
            "icon":            day.get("icon"),
        })

    return records


# ── Parsing: Stundendaten (forecast1) ─────────────────────────────────────────
def parse_hourly(raw: dict, station_id: str) -> list[dict]:
    """
    Parst forecast1: stündliche Temperatur- und Niederschlagswerte.
    Nützlich für stündliche Korrelationsanalyse mit Aufzugsfahrten.
    """
    station_data = raw.get(station_id) or raw.get(str(station_id), {})
    fc = station_data.get("forecast1", {})
    if not fc:
        return []

    start_ms = fc.get("start")
    step_ms  = fc.get("timeStep", 3_600_000)  # Standard: 1 Stunde
    temps    = fc.get("temperature", [])
    precips  = fc.get("precipitationTotal", [])

    if start_ms is None:
        return []

    records = []
    for i, temp in enumerate(temps):
        ts     = datetime.fromtimestamp((start_ms + i * step_ms) / 1000, tz=timezone.utc)
        precip = precips[i] if i < len(precips) else None
        records.append({
            "time":          ts,
            "station_id":    station_id,
            "temperature":   round(temp * _TEMP_SCALE, 1)    if temp   is not None else None,
            "precipitation": round(precip * _PRECIP_SCALE, 2) if precip is not None else None,
        })

    return records


# ── Datenbank-Writes (idempotent) ─────────────────────────────────────────────
def store_daily(conn, records: list[dict]) -> int:
    """Schreibt Tages-Records; ON CONFLICT → UPDATE (neueste DWD-Prognose gewinnt)."""
    count = 0
    with conn.cursor() as cur:
        for r in records:
            cur.execute(
                """
                INSERT INTO weather_observations
                    (time, station_id, temperature_min, temperature_max,
                     temperature_avg, precipitation, wind_speed, sunshine_min, icon, source)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'dwd_daily')
                ON CONFLICT (time, station_id) DO UPDATE SET
                    temperature_min = EXCLUDED.temperature_min,
                    temperature_max = EXCLUDED.temperature_max,
                    temperature_avg = EXCLUDED.temperature_avg,
                    precipitation   = EXCLUDED.precipitation,
                    wind_speed      = EXCLUDED.wind_speed,
                    sunshine_min    = EXCLUDED.sunshine_min,
                    icon            = EXCLUDED.icon
                """,
                (
                    r["time"], r["station_id"],
                    r["temperature_min"], r["temperature_max"], r["temperature_avg"],
                    r["precipitation"], r["wind_speed"], r["sunshine_min"], r["icon"],
                ),
            )
            count += 1
    conn.commit()
    return count


def store_hourly(conn, records: list[dict]) -> int:
    """Schreibt Stunden-Records in weather_hourly."""
    count = 0
    with conn.cursor() as cur:
        for r in records:
            cur.execute(
                """
                INSERT INTO weather_hourly (time, station_id, temperature, precipitation)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (time, station_id) DO UPDATE SET
                    temperature   = EXCLUDED.temperature,
                    precipitation = EXCLUDED.precipitation
                """,
                (r["time"], r["station_id"], r["temperature"], r["precipitation"]),
            )
            count += 1
    conn.commit()
    return count


# ── Hauptlogik ────────────────────────────────────────────────────────────────
def run_once() -> None:
    log.info("DWD-Poll für Station %s (Öhringen/Heilbronn) …", DWD_STATION_ID)
    try:
        raw     = fetch_dwd(DWD_STATION_ID)
        daily   = parse_daily(raw, DWD_STATION_ID)
        hourly  = parse_hourly(raw, DWD_STATION_ID)

        if not daily and not hourly:
            log.warning("DWD lieferte keine verwertbaren Daten.")
            return

        conn    = get_connection()
        d_count = store_daily(conn, daily)
        h_count = store_hourly(conn, hourly)
        conn.close()

        log.info(
            "DWD OK – %d Tages-Records (%s … %s), %d Stunden-Records gespeichert.",
            d_count,
            daily[0]["time"].strftime("%Y-%m-%d")  if daily  else "—",
            daily[-1]["time"].strftime("%Y-%m-%d") if daily  else "—",
            h_count,
        )
    except RetryError as exc:
        log.error("[ALERT] DWD-API nicht erreichbar nach allen Retry-Versuchen: %s", exc)
    except Exception as exc:
        log.exception("DWD-Poll fehlgeschlagen: %s", exc)


def main() -> None:
    parser = argparse.ArgumentParser(description="DWD Weather Poller für Heilbronn")
    parser.add_argument(
        "--loop", action="store_true",
        help=f"Dauerhaft pollen alle {DWD_POLL_INTERVAL}s (Standard: einmaliger Lauf)"
    )
    args = parser.parse_args()

    log.info("=== DWD Weather Poller gestartet ===")
    log.info("Station %s | Intervall: %ds | DB: %s@%s",
             DWD_STATION_ID, DWD_POLL_INTERVAL,
             DB_CONFIG["dbname"], DB_CONFIG["host"])

    run_once()

    if args.loop:
        log.info("Loop-Modus aktiv – nächster Poll in %ds.", DWD_POLL_INTERVAL)
        while True:
            time.sleep(DWD_POLL_INTERVAL)
            run_once()


if __name__ == "__main__":
    main()

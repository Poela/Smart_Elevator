"""
DWD Historical Weather Importer – Öhringen (nächste Station zu Heilbronn)
=========================================================================
Lädt historische Tagesdaten direkt vom DWD OpenData-Server herunter und
importiert sie in weather_observations – ohne manuelle Datei-Downloads.

Station:   Öhringen  (Stations_id 03761, WMO 10729, ~15 km von Heilbronn)
Datenquelle: https://opendata.dwd.de/climate_environment/CDC/
             observations_germany/climate/daily/kl/

Verfügbare Datenbereiche:
  recent   → letzten ~1,5 Jahre (wird täglich aktualisiert)
  historical → komplette Messreihe ab 1947

CSV-Spalten (werden automatisch gemappt):
  MESS_DATUM  → Datum (YYYYMMDD)
  TMK  → Tagesmittel Temperatur (°C)
  TXK  → Tagesmaximum Temperatur (°C)
  TNK  → Tagesminimum Temperatur (°C)
  RSK  → Niederschlagssumme (mm)
  SDK  → Sonnenscheindauer (Stunden)
  FM   → Mittlere Windgeschwindigkeit (m/s)

Nutzung:
  python dwd_history_importer.py                # recent (letzte ~18 Monate)
  python dwd_history_importer.py --range recent
  python dwd_history_importer.py --range historical   # komplett ab 1947
  python dwd_history_importer.py --range both          # alles auf einmal
  python dwd_history_importer.py --dry-run             # nur anzeigen, nicht schreiben
"""

import argparse
import io
import logging
import os
import zipfile
from datetime import datetime, timezone

import httpx
import pandas as pd
import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import execute_values
from tenacity import (
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
log = logging.getLogger("elevator.dwd_history")

# ── Konfiguration ─────────────────────────────────────────────────────────────
STATIONS_ID  = os.getenv("DWD_STATIONS_ID", "03761")   # Öhringen (interne DWD-ID für URL)
DB_STATION_ID = os.getenv("DWD_STATION_ID", "10729")  # WMO-ID – konsistent mit dwd_poller.py
DWD_BASE_URL = "https://opendata.dwd.de/climate_environment/CDC/observations_germany/climate/daily/kl"

DB_CONFIG = {
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME",     "elevator_db"),
    "user":     os.getenv("DB_USER",     "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),
}

# Mapping: CSV-Spalte → interne Bedeutung
_COL_MAP = {
    "mess_datum": "date",
    "tmk":        "temperature_avg",   # Tagesmittel  °C
    "txk":        "temperature_max",   # Tagesmaximum °C
    "tnk":        "temperature_min",   # Tagesminimum °C
    "rsk":        "precipitation",     # Niederschlag mm
    "sdk":        "sunshine_h",        # Sonnenstunden h
    "fm":         "wind_speed_ms",     # Wind m/s → später → km/h
}

# Sentinel-Werte des DWD die als "kein Messwert" interpretiert werden
_DWD_NULL = {-999.0, -999, -9999.0, -9999}


# ── Download-URL ermitteln ────────────────────────────────────────────────────
def build_url(stations_id: str, data_range: str) -> str:
    """
    Konstruiert die ZIP-Download-URL für die gewünschte Station.

    DWD-Namenskonvention:
      recent:     tageswerte_KL_{id}_akt.zip
      historical: tageswerte_KL_{id}_{von}_{bis}_hist.zip
                  (Dateiname wird aus dem Verzeichnis-Listing ermittelt)
    """
    sid = stations_id.zfill(5)
    if data_range == "recent":
        return f"{DWD_BASE_URL}/recent/tageswerte_KL_{sid}_akt.zip"
    # historical: Dateiname enthält Datumsbereich → Listing abfragen
    return None   # wird in fetch_historical_url() aufgelöst


@retry(
    stop=stop_after_attempt(4),
    wait=wait_exponential(multiplier=1, min=3, max=60),
    before_sleep=before_sleep_log(log, logging.WARNING),
    reraise=True,
)
def http_get(url: str) -> bytes:
    """HTTP-GET mit Retry + Backoff."""
    response = httpx.get(url, timeout=60.0, follow_redirects=True)
    response.raise_for_status()
    return response.content


def fetch_historical_url(stations_id: str) -> str:
    """
    Liest das DWD-Verzeichnis-Listing und findet den historischen ZIP-Dateinamen
    (enthält Start- und Enddatum im Namen, ändert sich bei jedem Update).
    """
    sid  = stations_id.zfill(5)
    base = f"{DWD_BASE_URL}/historical/"
    log.info("Suche historische ZIP-Datei im DWD-Verzeichnis …")
    html = http_get(base).decode("utf-8", errors="replace")
    # Dateinamen folgen dem Muster tageswerte_KL_XXXXX_*_hist.zip
    import re
    match = re.search(rf'(tageswerte_KL_{sid}_\d+_\d+_hist\.zip)', html)
    if not match:
        raise FileNotFoundError(
            f"Keine historische ZIP-Datei für Station {sid} im DWD-Verzeichnis gefunden.\n"
            f"Manuell prüfen: {base}"
        )
    filename = match.group(1)
    url = base + filename
    log.info("Gefunden: %s", url)
    return url


# ── ZIP laden und Mess-CSV extrahieren ────────────────────────────────────────
def load_csv_from_zip(raw_bytes: bytes) -> pd.DataFrame:
    """
    Entpackt die DWD-ZIP-Datei im Arbeitsspeicher und liest die Tagesdaten-CSV.
    DWD packt genau eine Datei 'produkt_klima_tag_*.txt' (Semikolon-getrennt).
    """
    with zipfile.ZipFile(io.BytesIO(raw_bytes)) as zf:
        csv_files = [n for n in zf.namelist() if n.startswith("produkt_klima_tag")]
        if not csv_files:
            raise ValueError(
                f"Keine 'produkt_klima_tag_*.txt'-Datei im ZIP gefunden. "
                f"Inhalt: {zf.namelist()}"
            )
        with zf.open(csv_files[0]) as f:
            df = pd.read_csv(f, sep=";", encoding="latin-1", skipinitialspace=True)

    # Spaltennamen normalisieren (lowercase, kein Leerzeichen)
    df.columns = [c.strip().lower() for c in df.columns]
    log.debug("ZIP-Spalten: %s", list(df.columns))
    return df


# ── Daten bereinigen und transformieren ───────────────────────────────────────
def transform(df: pd.DataFrame) -> pd.DataFrame:
    """
    Wählt relevante Spalten, bereinigt DWD-Sentinel-Werte (-999),
    wandelt Datum in UTC-Timestamp um und berechnet Wind in km/h.
    """
    available = {k: v for k, v in _COL_MAP.items() if k in df.columns}
    missing   = set(_COL_MAP.keys()) - set(available.keys())
    if missing:
        log.warning("Fehlende Spalten (werden übersprungen): %s", missing)

    df = df[list(available.keys())].copy()
    df.rename(columns=available, inplace=True)

    # Datum parsen: DWD-Format YYYYMMDD → UTC-Timestamp (Mittag)
    df["time"] = pd.to_datetime(df["date"].astype(str), format="%Y%m%d", errors="coerce")
    df["time"] = df["time"].apply(
        lambda d: d.replace(hour=12, tzinfo=timezone.utc) if pd.notna(d) else None
    )
    df.dropna(subset=["time"], inplace=True)

    # Sentinel-Werte → NaN
    numeric_cols = [c for c in df.columns if c not in ("date", "time")]
    for col in numeric_cols:
        df[col] = pd.to_numeric(df[col], errors="coerce")
        df.loc[df[col].isin(_DWD_NULL), col] = None

    # Windgeschwindigkeit: m/s → km/h als REAL (kein Integer – Dezimalwert bleibt)
    if "wind_speed_ms" in df.columns:
        df["wind_speed"] = (df["wind_speed_ms"] * 3.6).round(1)
        df.drop(columns=["wind_speed_ms"], inplace=True)

    # Sonnenstunden → Minuten als Integer
    if "sunshine_h" in df.columns:
        df["sunshine_min"] = (df["sunshine_h"] * 60).round(0)
        df.drop(columns=["sunshine_h"], inplace=True)

    df.drop(columns=["date"], inplace=True, errors="ignore")
    return df


# ── Hilfsfunktionen: NaN/NA sicher in Python-Native-Typen wandeln ─────────────
def _f(val) -> float | None:
    """Float oder None – NaN und pd.NA werden zu None."""
    try:
        if pd.isna(val):
            return None
    except (TypeError, ValueError):
        pass
    return float(val) if val is not None else None


def _i(val) -> int | None:
    """Int oder None – NaN, pd.NA und Floats werden sicher konvertiert."""
    try:
        if pd.isna(val):
            return None
    except (TypeError, ValueError):
        pass
    return int(round(float(val))) if val is not None else None


# ── In DB schreiben ───────────────────────────────────────────────────────────
def store(conn, df: pd.DataFrame, stations_id: str, dry_run: bool = False) -> int:
    """
    Schreibt transformierte Wetterdaten in weather_observations.
    ON CONFLICT (time, station_id) DO UPDATE → neueste Werte überschreiben alte.
    Idempotent: beliebig oft wiederholbar.
    """
    records = []
    for _, row in df.iterrows():
        if row["time"] is None:
            continue
        records.append((
            row["time"],
            stations_id,
            _f(row.get("temperature_avg")),
            _f(row.get("temperature_max")),
            _f(row.get("temperature_min")),
            _f(row.get("precipitation")),
            _f(row.get("wind_speed")),      # REAL in DB – kein Integer-Cast nötig
            _i(row.get("sunshine_min")),    # INTEGER in DB – sicher gerundet
            None,                           # icon (nur von API)
            "dwd_opendata",
        ))

    if dry_run:
        log.info("[DRY-RUN] Würde %d Records schreiben (kein DB-Write).", len(records))
        if records:
            log.info("  Beispiel: %s", records[0])
        return len(records)

    if not records:
        log.warning("Keine gültigen Records zum Schreiben.")
        return 0

    with conn.cursor() as cur:
        execute_values(
            cur,
            """
            INSERT INTO weather_observations
                (time, station_id, temperature_avg, temperature_max, temperature_min,
                 precipitation, wind_speed, sunshine_min, icon, source)
            VALUES %s
            ON CONFLICT (time, station_id) DO UPDATE SET
                temperature_avg = EXCLUDED.temperature_avg,
                temperature_max = EXCLUDED.temperature_max,
                temperature_min = EXCLUDED.temperature_min,
                precipitation   = EXCLUDED.precipitation,
                wind_speed      = EXCLUDED.wind_speed,
                sunshine_min    = EXCLUDED.sunshine_min
            """,
            records,
            page_size=500,
        )
    conn.commit()
    return len(records)


# ── Hauptprogramm ─────────────────────────────────────────────────────────────
def import_range(data_range: str, dry_run: bool) -> None:
    log.info("=== DWD History Import: %s ===", data_range)

    if data_range == "recent":
        url = build_url(STATIONS_ID, "recent")
    else:
        url = fetch_historical_url(STATIONS_ID)

    log.info("Lade ZIP von: %s", url)
    raw   = http_get(url)
    log.info("Download abgeschlossen (%.1f MB).", len(raw) / 1_048_576)

    df    = load_csv_from_zip(raw)
    df    = transform(df)

    log.info(
        "%d Tages-Records geladen: %s → %s",
        len(df),
        df["time"].min().strftime("%Y-%m-%d") if len(df) else "–",
        df["time"].max().strftime("%Y-%m-%d") if len(df) else "–",
    )

    if not dry_run:
        conn  = psycopg2.connect(**DB_CONFIG)
        count = store(conn, df, DB_STATION_ID, dry_run=False)
        conn.close()
        log.info("✓ %d Records in weather_observations gespeichert.", count)
    else:
        store(None, df, DB_STATION_ID, dry_run=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="DWD Historische Wetterdaten importieren (Öhringen / Heilbronn)"
    )
    parser.add_argument(
        "--range",
        choices=["recent", "historical", "both"],
        default="recent",
        help=(
            "recent     = letzte ~18 Monate (Standard)\n"
            "historical = komplette Messreihe ab 1947\n"
            "both       = beides (empfohlen für maximale Datenbasis)"
        ),
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Daten laden und anzeigen, aber NICHT in die DB schreiben"
    )
    args = parser.parse_args()

    log.info("Station: %s (Öhringen / Heilbronn) | DB-ID: %s | dry-run: %s",
             STATIONS_ID, DB_STATION_ID, args.dry_run)

    if args.range in ("recent", "both"):
        import_range("recent", args.dry_run)
    if args.range in ("historical", "both"):
        import_range("historical", args.dry_run)

    log.info("=== Import abgeschlossen ===")
    if not args.dry_run:
        log.info(
            "Tipp: Korrelationsanalyse in Grafana unter "
            "'Daten & Analyse → 🌦️ Wetter-Korrelation' prüfen."
        )


if __name__ == "__main__":
    main()

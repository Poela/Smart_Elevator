"""
Elevator Monitoring – CSV Importer (Phase 1)
============================================
Liest alle CSV-Dateien ein und schreibt sie in PostgreSQL/TimescaleDB.

Verwendung:
    python csv_importer.py

Voraussetzungen:
    pip install pandas psycopg2-binary python-dotenv

Umgebungsvariablen (.env):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
"""

import os
import logging
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from pathlib import Path
from dotenv import load_dotenv

# ── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

# ── Konfiguration ───────────────────────────────────────────────────────────
load_dotenv()

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

# CSV-Dateien → Aufzugsname (muss mit elevators.name in der DB übereinstimmen)
CSV_FILES = {
    "Aufzug links L-Bau.csv":       "Aufzug links L-Bau",
    "Aufzug rechts L-Bau.csv":      "Aufzug rechts L-Bau",
    "Campus Brücken HN West.csv": "Campus Brücken HN West",
    "Feuerwehraufzug L-Bau.csv":    "Feuerwehraufzug L-Bau",
}

CSV_DIR = Path(__file__).parent / "History_Daten_Elevator"


# ── Datenbankverbindung ─────────────────────────────────────────────────────
def get_connection():
    """Gibt eine psycopg2-Verbindung zurück."""
    return psycopg2.connect(**DB_CONFIG)


# ── Hilfsfunktionen ─────────────────────────────────────────────────────────
def get_elevator_id(conn, name: str) -> int:
    """Gibt die elevator_id für einen Aufzugsnamen zurück."""
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM elevators WHERE name = %s", (name,))
        row = cur.fetchone()
        if row is None:
            raise ValueError(f"Aufzug '{name}' nicht in der Datenbank gefunden. "
                             "Bitte zuerst schema.sql ausführen.")
        return row[0]


def load_csv(filepath: Path) -> pd.DataFrame:
    """Liest eine Elevator-CSV-Datei ein und gibt ein bereinigtes DataFrame zurück."""
    df = pd.read_csv(
        filepath,
        sep=";",
        parse_dates=["Timestamp"],
    )

    # Spaltennamen normalisieren
    df.columns = [c.strip().lower() for c in df.columns]
    df.rename(columns={"timestamp": "time", "floor": "floor"}, inplace=True)

    # Ungültige Zeilen entfernen
    before = len(df)
    df.dropna(subset=["time", "floor"], inplace=True)
    df = df[df["floor"] >= 0]
    after = len(df)

    if before != after:
        log.warning(f"  {before - after} ungültige Zeilen entfernt.")

    # Duplikate entfernen (gleicher Timestamp + gleiche Etage)
    df.drop_duplicates(subset=["time", "floor"], inplace=True)

    return df


def insert_events(conn, elevator_id: int, df: pd.DataFrame, source: str = "csv"):
    """Schreibt Events per Batch in elevator_events."""
    records = [
        (row["time"].to_pydatetime(), elevator_id, int(row["floor"]), source)
        for _, row in df.iterrows()
    ]

    with conn.cursor() as cur:
        execute_values(
            cur,
            """
            INSERT INTO elevator_events (time, elevator_id, floor, source)
            VALUES %s
            ON CONFLICT DO NOTHING
            """,
            records,
        )
    conn.commit()
    return len(records)


# ── Hauptprogramm ───────────────────────────────────────────────────────────
def main():
    log.info("=== Elevator CSV-Importer gestartet ===")

    conn = get_connection()
    log.info(f"Verbunden mit Datenbank '{DB_CONFIG['dbname']}' auf {DB_CONFIG['host']}")

    total_imported = 0

    for filename, elevator_name in CSV_FILES.items():
        filepath = CSV_DIR / filename

        if not filepath.exists():
            log.warning(f"Datei nicht gefunden: {filepath} – übersprungen.")
            continue

        log.info(f"Verarbeite: {filename}")

        try:
            elevator_id = get_elevator_id(conn, elevator_name)
            df = load_csv(filepath)
            count = insert_events(conn, elevator_id, df)
            total_imported += count
            log.info(f"  ✓ {count} Datensätze importiert (Aufzug-ID: {elevator_id})")

        except Exception as e:
            log.error(f"  ✗ Fehler bei '{filename}': {e}")
            conn.rollback()

    conn.close()
    log.info(f"=== Import abgeschlossen: {total_imported} Datensätze gesamt ===")


if __name__ == "__main__":
    main()

"""
Elevator Monitoring – API Poller (Phase 2)
==========================================
Polls the external elevator API at a configurable interval and writes the
current floor position of each elevator into PostgreSQL/TimescaleDB.

Verwendung:
    pip install -r requirements.txt
    python api_poller.py

Umgebungsvariablen (.env):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
    ELEVATOR_API_URL    – Base URL of the elevator API
    ELEVATOR_API_KEY    – Bearer token / API key (leave empty if not needed)
    POLL_INTERVAL_SEC   – Polling interval in seconds (default: 60)

TODO: Adjust fetch_elevator_data() to match the actual API response format.
"""

import os
import time
import logging
from datetime import datetime, timezone

import psycopg2
from dotenv import load_dotenv

try:
    import httpx
    HTTP_AVAILABLE = True
except ImportError:
    HTTP_AVAILABLE = False

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

API_URL       = os.getenv("ELEVATOR_API_URL", "http://localhost:8080/api/elevators")
API_KEY       = os.getenv("ELEVATOR_API_KEY", "")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL_SEC", "60"))


def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def fetch_elevator_data() -> list[dict]:
    """
    Fetch current elevator positions from the API.
    Returns a list of dicts: [{"elevator_name": str, "floor": int}, ...]

    TODO: Adapt the field mapping below to match the actual API response.
    Example expected API response:
        [
            {"name": "Aufzug links L-Bau", "currentFloor": 3},
            {"name": "Aufzug rechts L-Bau", "currentFloor": 7},
            ...
        ]
    """
    if not HTTP_AVAILABLE:
        log.error("httpx is not installed. Run: pip install httpx")
        return []

    headers = {}
    if API_KEY:
        headers["Authorization"] = f"Bearer {API_KEY}"

    try:
        response = httpx.get(API_URL, headers=headers, timeout=10.0)
        response.raise_for_status()
        raw = response.json()

        return [
            {
                "elevator_name": item.get("name"),           # TODO: adjust key
                "floor":         item.get("currentFloor"),   # TODO: adjust key
            }
            for item in raw
        ]

    except httpx.HTTPStatusError as e:
        log.error(f"API returned HTTP {e.response.status_code}: {e}")
    except httpx.RequestError as e:
        log.error(f"API request failed: {e}")

    return []


def insert_event(conn, elevator_name: str, floor: int, ts: datetime):
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM elevators WHERE name = %s", (elevator_name,))
        row = cur.fetchone()
        if row is None:
            log.warning(f"Unknown elevator '{elevator_name}' – not in DB, skipping.")
            return

        cur.execute(
            """
            INSERT INTO elevator_events (time, elevator_id, floor, source)
            VALUES (%s, %s, %s, 'api')
            ON CONFLICT DO NOTHING
            """,
            (ts, row[0], floor),
        )
    conn.commit()


def poll_once(conn):
    now = datetime.now(timezone.utc)
    data = fetch_elevator_data()

    if not data:
        log.debug("No data received from API.")
        return

    for item in data:
        name  = item.get("elevator_name")
        floor = item.get("floor")

        if name is None or floor is None:
            log.warning(f"Incomplete API record: {item}")
            continue

        insert_event(conn, name, int(floor), now)
        log.info(f"  ✓ {name}: Stockwerk {floor}")


def main():
    if not HTTP_AVAILABLE:
        log.error("Please install httpx before running the API poller: pip install httpx")
        return

    log.info("=== Elevator API Poller gestartet ===")
    log.info(f"API URL:         {API_URL}")
    log.info(f"Poll-Intervall:  {POLL_INTERVAL}s")

    conn = get_connection()
    log.info(f"DB verbunden:    {DB_CONFIG['dbname']}@{DB_CONFIG['host']}")

    try:
        while True:
            log.info("Polling …")
            try:
                poll_once(conn)
            except psycopg2.Error as exc:
                log.error(f"DB-Fehler: {exc} – reconnecting …")
                conn = get_connection()

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        log.info("Poller gestoppt.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()

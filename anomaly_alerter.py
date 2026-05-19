"""
Anomalie-Alerting-Service
==========================
Prueft regelmaessig die v_trip_anomalies-View auf auffaellige
Fahrtenmuster und schreibt strukturierte Alerts ins Log sowie
in die alert_log-Tabelle (Audit-Trail).

Logik:
  Taeglich um 07:00 Uhr und nach jedem manuellen Start wird
  der gestrige Tag ausgewertet. Erkannte Anomalien werden
  klassifiziert:
    Z-Score > 2.0  -> KRITISCH (Ausreisser)
    Z-Score > 1.5  -> WARNUNG  (Auffaellig)

Nutzung:
  python anomaly_alerter.py            # einmaliger Lauf (gestern)
  python anomaly_alerter.py --loop     # taeglich 07:00 Uhr
  python anomaly_alerter.py --days 7   # letzte 7 Tage pruefen

Observability:
  GET /metrics  -> Prometheus (Port 8082)
  GET /health   -> DB-Status
  elevator_alert_total       - Gesamtanzahl erkannter Anomalien
  elevator_alert_critical    - Davon KRITISCH (|z| > 2.0)
  elevator_last_check_time   - Unix-Timestamp letzte Prüfung
"""

import argparse
import json
import logging
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg2
import pytz
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from dotenv import load_dotenv
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    REGISTRY,
    generate_latest,
)

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
log = logging.getLogger("elevator.alerter")

BERLIN_TZ    = pytz.timezone("Europe/Berlin")
METRICS_PORT = int(os.getenv("ALERT_METRICS_PORT", "8082"))

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),
}

# Schwellenwerte (ueberschreibbar per Umgebungsvariable)
Z_CRITICAL  = float(os.getenv("ALERT_Z_CRITICAL", "2.0"))
Z_WARNING   = float(os.getenv("ALERT_Z_WARNING",  "1.5"))

# ── Prometheus-Metriken ───────────────────────────────────────────────────────
ALERT_TOTAL = Counter(
    "elevator_alert_total",
    "Gesamtanzahl erkannter Anomalien seit Programmstart",
    ["elevator", "severity"],
)
LAST_CHECK = Gauge(
    "elevator_last_check_unixtime",
    "Unix-Timestamp der letzten Anomalie-Pruefung",
)

# ── DB ────────────────────────────────────────────────────────────────────────
_thread_local = threading.local()


def get_conn():
    conn = getattr(_thread_local, "conn", None)
    try:
        if conn is None or conn.closed:
            raise psycopg2.OperationalError
        conn.cursor().execute("SELECT 1")
    except psycopg2.Error:
        conn = psycopg2.connect(**DB_CONFIG)
        _thread_local.conn = conn
        _ensure_alert_log(conn)
    return conn


def _ensure_alert_log(conn) -> None:
    """Legt die alert_log-Tabelle an, falls sie noch nicht existiert."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS alert_log (
                id           SERIAL PRIMARY KEY,
                triggered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                elevator     TEXT        NOT NULL,
                check_day    DATE        NOT NULL,
                severity     TEXT        NOT NULL,
                z_score      REAL        NOT NULL,
                trips        INTEGER     NOT NULL,
                expected     REAL        NOT NULL,
                message      TEXT        NOT NULL
            )
        """)
        cur.execute("""
            CREATE INDEX IF NOT EXISTS idx_alert_log_elevator_day
                ON alert_log (elevator, check_day DESC)
        """)
    conn.commit()


# ── Kern-Logik ────────────────────────────────────────────────────────────────
def check_anomalies(days_back: int = 1) -> int:
    """
    Prueft die letzten `days_back` Tage auf Anomalien.
    Gibt die Anzahl erkannter Anomalien zurueck.

    Klassifikation (konfigurierbar per Umgebungsvariable):
      |z_score| > Z_CRITICAL (Standard 2.0) -> KRITISCH
      |z_score| > Z_WARNING  (Standard 1.5) -> WARNUNG
    """
    since = (datetime.now(timezone.utc) - timedelta(days=days_back)).date()

    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("""
            SELECT
                time::date      AS day,
                elevator_name,
                trips,
                expected_trips,
                z_score,
                anomaly_status
            FROM v_trip_anomalies
            WHERE time::date >= %s
              AND anomaly_status != 'Normal'
            ORDER BY ABS(z_score) DESC
        """, (since,))
        rows = cur.fetchall()

    found = 0
    for day, elevator, trips, expected, z_score, status in rows:
        severity = "KRITISCH" if abs(z_score) >= Z_CRITICAL else "WARNUNG"
        msg = (
            f"Anomalie erkannt | Aufzug: {elevator} | Tag: {day} | "
            f"Fahrten: {trips} (erwartet: {expected:.1f}) | "
            f"Z-Score: {z_score:+.2f} | Status: {status}"
        )

        if severity == "KRITISCH":
            log.error("[ALERT][%s] %s", severity, msg)
        else:
            log.warning("[ALERT][%s] %s", severity, msg)

        ALERT_TOTAL.labels(elevator=elevator, severity=severity).inc()

        # Persistenter Audit-Trail
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO alert_log
                    (elevator, check_day, severity, z_score, trips, expected, message)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING
            """, (elevator, day, severity, float(z_score), int(trips),
                  float(expected), msg))
        conn.commit()
        found += 1

    LAST_CHECK.set(time.time())

    if found == 0:
        log.info("Keine Anomalien im Zeitraum seit %s gefunden.", since)
    else:
        log.info("Pruefung abgeschlossen: %d Anomalie(n) erkannt.", found)

    return found


# ── Health/Metrics HTTP-Server (:8082) ────────────────────────────────────────
class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args) -> None:
        pass

    def do_GET(self) -> None:
        if self.path == "/health":
            try:
                get_conn().cursor().execute("SELECT 1")
                body, code = b'{"status":"ok"}', 200
            except Exception as exc:
                body = json.dumps({"status": "degraded", "error": str(exc)}).encode()
                code = 503
            self._respond(code, "application/json", body)
        elif self.path == "/metrics":
            self._respond(200, CONTENT_TYPE_LATEST, generate_latest(REGISTRY))
        else:
            self._respond(404, "application/json", b'{"error":"not found"}')

    def _respond(self, code, ct, body):
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ── Einstiegspunkt ────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description="Elevator Anomalie-Alerter")
    parser.add_argument("--loop",     action="store_true",
                        help="Taeglich 07:00 Uhr pruefen (Dauerbetrieb)")
    parser.add_argument("--days",     type=int, default=1,
                        help="Wie viele Tage zurueck pruefen (Standard: 1)")
    args = parser.parse_args()

    log.info("=== Anomalie-Alerter | Z-kritisch=%.1f | Z-warn=%.1f ===",
             Z_CRITICAL, Z_WARNING)

    # Health/Metrics-Server auf Port 8082
    server = HTTPServer(("0.0.0.0", METRICS_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True, name="alert-http").start()
    log.info("Metrics-Server laeuft auf Port %d (/health, /metrics)", METRICS_PORT)

    # Einmaliger Lauf (sofort)
    check_anomalies(days_back=args.days)

    if not args.loop:
        server.shutdown()
        return

    # Dauerbetrieb: taeglich 07:00 Uhr Berliner Zeit
    scheduler = BackgroundScheduler(timezone=BERLIN_TZ)
    scheduler.add_job(
        check_anomalies,
        trigger=CronTrigger(hour=7, minute=0, timezone=BERLIN_TZ),
        kwargs={"days_back": 1},
        id="daily_anomaly_check",
        max_instances=1,
        coalesce=True,
    )
    scheduler.start()
    log.info("Scheduler aktiv – naechste Pruefung taeglich 07:00 Uhr. Ctrl+C zum Beenden.")

    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        log.info("Beende Alerter ...")
    finally:
        scheduler.shutdown(wait=False)
        server.shutdown()
        log.info("Alerter gestoppt.")


if __name__ == "__main__":
    main()

"""
Elevator Monitoring – Produktions-API-Poller (Phase 2)
=======================================================

Architektur-Übersicht:
  ┌────────────────────────────────────────────────────────────────────┐
  │  APScheduler (BackgroundScheduler, TZ: Europe/Berlin, DST-sicher) │
  │  └─ Job pro Quelle aus poller_config.yaml                          │
  │       ├─ RateLimiter    (Token-Bucket, konfigurierbar / Quelle)    │
  │       ├─ CircuitBreaker (CLOSED → OPEN → HALF_OPEN)                │
  │       ├─ fetch_with_retry (Tenacity, Exp. Backoff 2 s → 60 s)      │
  │       ├─ LastValueCache  (In-Memory Fallback bei Ausfall)           │
  │       ├─ insert_event   (TimescaleDB, ON CONFLICT DO NOTHING)       │
  │       └─ DeadLetterQueue (elevator_events_dlq, replay-fähig)       │
  └────────────────────────────────────────────────────────────────────┘
  ┌────────────────────────────────────────────────────────────────────┐
  │  HTTP Server (Port 8080)                                            │
  │  ├─ GET /health  → 200/503  (DB-Ping + CB-Status)                  │
  │  ├─ GET /ready   → 200/503  (Scheduler aktiv?)                     │
  │  └─ GET /metrics → Prometheus Text Format                          │
  └────────────────────────────────────────────────────────────────────┘

Fehlerklassifikation:
  Transient:  Netzwerk-Timeout, HTTP 429/500/502/503/504
              → Retry mit Exponential Backoff (max 5 Versuche, 2→60 s)
  Permanent:  HTTP 401/403/404
              → Kein Retry, CRITICAL-Log, Circuit Breaker bleibt offen

Idempotenz:  ON CONFLICT DO NOTHING auf (time, elevator_id) –
             wiederholte Polls schreiben keinen doppelten Datensatz.

Zeitzonen:   Intern immer UTC gespeichert.
             Scheduling-Trigger in Europe/Berlin (APScheduler + pytz).
             Bei Sommer-/Winterzeitumstellung bleibt das Intervall stabil,
             da APScheduler die Wall-Clock-Zeit in UTC umrechnet.

Konfiguration: poller_config.yaml – neue Endpunkte/Sensoren ohne
               Code-Änderung ergänzen (config-driven ingest).
"""

import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum, auto
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, Optional

import psycopg2
import pytz
import yaml
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from dotenv import load_dotenv
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    REGISTRY,
    generate_latest,
)
from tenacity import (
    RetryError,
    before_sleep_log,
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

try:
    import httpx
    HTTP_AVAILABLE = True
except ImportError:
    HTTP_AVAILABLE = False

load_dotenv()

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
log = logging.getLogger("elevator.poller")

BERLIN_TZ = pytz.timezone("Europe/Berlin")

# ── Umgebungskonfiguration ───────────────────────────────────────────────────
DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),
}
CONFIG_PATH  = Path(os.getenv("POLLER_CONFIG", "poller_config.yaml"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "8080"))

# Circuit-Breaker-Schwellen
CB_FAILURE_THRESHOLD = int(os.getenv("CB_FAILURE_THRESHOLD", "5"))
CB_RECOVERY_TIMEOUT  = int(os.getenv("CB_RECOVERY_TIMEOUT_SEC", "60"))

# ── Prometheus-Metriken ──────────────────────────────────────────────────────
POLL_TOTAL = Counter(
    "elevator_poll_total",
    "Gesamtanzahl der API-Abfragen",
    ["source"],
)
POLL_ERRORS = Counter(
    "elevator_poll_errors_total",
    "Fehlgeschlagene Abfragen nach Quelle und Fehlertyp",
    ["source", "error_type"],
)
CURRENT_FLOOR = Gauge(
    "elevator_floor_current",
    "Zuletzt bekanntes Stockwerk je Aufzug",
    ["elevator_name"],
)
POLL_DURATION = Histogram(
    "elevator_poll_duration_seconds",
    "Dauer eines vollständigen Poll-Zyklus in Sekunden",
    ["source"],
    buckets=[0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0],
)
CB_OPEN = Gauge(
    "elevator_circuit_breaker_open",
    "Circuit-Breaker-Status: 1=OPEN, 0=CLOSED/HALF_OPEN",
    ["source"],
)
DLQ_SIZE = Gauge(
    "elevator_dlq_size_total",
    "Nicht aufgelöste Einträge in der Dead-Letter-Queue",
)
LAST_POLL_OK = Gauge(
    "elevator_last_successful_poll_unixtime",
    "Unix-Timestamp des letzten erfolgreichen Polls",
    ["source"],
)

# ── Last-Value-Cache (Fallback bei Quellausfall) ─────────────────────────────
_last_known: Dict[str, Dict[str, Any]] = {}
_cache_lock = threading.Lock()


# ── Circuit Breaker ──────────────────────────────────────────────────────────
class CBState(Enum):
    CLOSED    = auto()  # Normalbetrieb
    OPEN      = auto()  # Quelle ausgefallen – keine Requests
    HALF_OPEN = auto()  # Erholungstest – ein Probe-Request erlaubt


@dataclass
class CircuitBreaker:
    """
    Einfacher zustandsbehafteter Circuit Breaker.

    Schwellenwert (CB_FAILURE_THRESHOLD) aufeinanderfolgende Fehler
    öffnen den Breaker. Nach CB_RECOVERY_TIMEOUT Sekunden wechselt
    er in HALF_OPEN und lässt einen Test-Request durch.
    """
    name: str
    threshold: int        = CB_FAILURE_THRESHOLD
    recovery_timeout: int = CB_RECOVERY_TIMEOUT
    state: CBState        = CBState.CLOSED
    failure_count: int    = 0
    opened_at: float      = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record_success(self) -> None:
        with self._lock:
            self.failure_count = 0
            self.state = CBState.CLOSED
            CB_OPEN.labels(source=self.name).set(0)

    def record_failure(self) -> None:
        with self._lock:
            self.failure_count += 1
            if (
                self.failure_count >= self.threshold
                and self.state == CBState.CLOSED
            ):
                self.state = CBState.OPEN
                self.opened_at = time.monotonic()
                CB_OPEN.labels(source=self.name).set(1)
                log.error(
                    "[ALERT][%s] Circuit Breaker OPEN nach %d Fehlern – "
                    "Requests pausiert für %ds.",
                    self.name, self.failure_count, self.recovery_timeout,
                )

    def allow_request(self) -> bool:
        with self._lock:
            if self.state == CBState.CLOSED:
                return True
            if self.state == CBState.OPEN:
                if time.monotonic() - self.opened_at >= self.recovery_timeout:
                    self.state = CBState.HALF_OPEN
                    log.info("[%s] Circuit Breaker → HALF_OPEN (Probe-Request).", self.name)
                    return True
                return False
            return True  # HALF_OPEN: einen Test durchlassen


# ── Rate Limiter (Token Bucket) ───────────────────────────────────────────────
class RateLimiter:
    """
    Einfacher Token-Bucket-Rate-Limiter.
    Sorgt für Fairness gegenüber der Quelle (max. rps Requests/Sekunde).
    """

    def __init__(self, rps: float = 1.0) -> None:
        self._min_interval = 1.0 / rps if rps > 0 else 0.0
        self._last_call = 0.0
        self._lock = threading.Lock()

    def acquire(self) -> None:
        with self._lock:
            wait = self._min_interval - (time.monotonic() - self._last_call)
            if wait > 0:
                time.sleep(wait)
            self._last_call = time.monotonic()


# ── DB-Verbindung (thread-lokal, auto-reconnect) ──────────────────────────────
_thread_local = threading.local()


def get_connection() -> psycopg2.extensions.connection:
    """Gibt eine thread-lokale DB-Verbindung zurück; reconnect bei Bedarf."""
    conn: Optional[psycopg2.extensions.connection] = getattr(_thread_local, "conn", None)
    try:
        if conn is None or conn.closed:
            raise psycopg2.OperationalError("no connection")
        conn.cursor().execute("SELECT 1")
    except psycopg2.Error:
        conn = psycopg2.connect(**DB_CONFIG)
        _thread_local.conn = conn
        log.info("DB-Verbindung (neu) hergestellt für Thread %s.", threading.current_thread().name)
    return conn


# ── Hilfsfunktion: Umgebungsvariablen in Config-Werten expandieren ────────────
def expand_env(value: str) -> str:
    """Expandiert ${VAR_NAME} in Konfig-Strings."""
    return re.sub(r"[$][{]([^}]+)[}]", lambda m: os.getenv(m.group(1), ""), str(value))


# ── Dead-Letter Queue ─────────────────────────────────────────────────────────
def push_to_dlq(conn, payload: dict, error_msg: str) -> None:
    """Speichert einen fehlgeschlagenen Record in elevator_events_dlq."""
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO elevator_events_dlq (payload, error_msg) VALUES (%s, %s)",
                (json.dumps(payload), error_msg[:500]),
            )
        conn.commit()
        log.warning("DLQ: Record gespeichert – %s", error_msg[:80])
    except Exception as exc:
        log.error("DLQ-Insert fehlgeschlagen: %s", exc)


def refresh_dlq_metric(conn) -> None:
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM elevator_events_dlq WHERE resolved_at IS NULL")
            DLQ_SIZE.set(cur.fetchone()[0])
    except Exception:
        pass


# ── HTTP-Abfrage mit Retry & Exponential Backoff ──────────────────────────────
_PERMANENT_STATUS = {401, 403, 404}
_TRANSIENT_STATUS = {429, 500, 502, 503, 504}


def fetch_with_retry(url: str, headers: dict, timeout: float, source_name: str) -> list:
    """
    Holt Daten von der API.

    Transiente Fehler (Netzwerk, HTTP 429/5xx):
        Retry mit Exponential Backoff (2 s → 60 s, max. 5 Versuche).
    Permanente Fehler (HTTP 401/403/404):
        Sofortiger Abbruch, CRITICAL-Log, kein Retry.
    """
    if not HTTP_AVAILABLE:
        raise RuntimeError("httpx nicht installiert – pip install httpx")

    @retry(
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=60),
        retry=retry_if_exception_type((httpx.RequestError, httpx.TimeoutException)),
        before_sleep=before_sleep_log(log, logging.WARNING),
        reraise=True,
    )
    def _do_request() -> list:
        response = httpx.get(url, headers=headers, timeout=timeout)
        if response.status_code in _PERMANENT_STATUS:
            log.critical(
                "[PERMANENT ERROR][%s] HTTP %d – kein Retry. Konfiguration prüfen.",
                source_name, response.status_code,
            )
            POLL_ERRORS.labels(source=source_name, error_type="permanent_http").inc()
            return []
        if response.status_code in _TRANSIENT_STATUS:
            # Als transient klassifizieren → Retry durch Tenacity
            raise httpx.RequestError(f"Transient HTTP {response.status_code}")
        response.raise_for_status()
        data = response.json()
        # Einzelobjekt (z. B. /controllers/{id}) → in Liste einwickeln
        return data if isinstance(data, list) else [data]

    return _do_request()


# ── Verschachtelter Feldzugriff (Dot-Notation) ───────────────────────────────
def _get_nested(item: dict, path: str) -> Any:
    """Liest verschachtelte Felder per Dot-Notation, z. B. 'liftStatus.car.floor'."""
    val: Any = item
    for key in path.split("."):
        if not isinstance(val, dict):
            return None
        val = val.get(key)
    return val


# ── Feld-Mapping (config-driven) ──────────────────────────────────────────────
def map_response(raw: list, mapping: dict) -> list[dict]:
    """Mappt API-Felder auf interne Struktur anhand der Config.

    Unterstützt Dot-Notation für verschachtelte Felder,
    z. B. 'liftStatus.car.floor'.
    Optional: 'elevator_name_override' überschreibt den API-Namen mit
    einem festen DB-Namen (nützlich wenn API- und DB-Name abweichen).
    """
    override = mapping.get("elevator_name_override")
    items    = [raw] if isinstance(raw, dict) else (raw or [])
    result   = []
    for item in items:
        name  = override if override else _get_nested(item, mapping.get("elevator_name", "name"))
        floor = _get_nested(item, mapping.get("floor", "currentFloor"))
        if name is not None and floor is not None:
            try:
                result.append({"elevator_name": str(name), "floor": int(floor)})
            except (ValueError, TypeError) as exc:
                log.warning("Ungültiger Record %s – %s", item, exc)
    return result


# ── DB-Insert (idempotent) ────────────────────────────────────────────────────
def insert_event(
    conn, elevator_name: str, floor: int, ts: datetime, source: str
) -> bool:
    """
    Schreibt ein Fahrt-Ereignis.
    ON CONFLICT DO NOTHING garantiert Idempotenz bei Doppelpoll.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM elevators WHERE name = %s", (elevator_name,))
        row = cur.fetchone()
        if row is None:
            log.warning("Unbekannter Aufzug '%s' – nicht in elevators-Tabelle.", elevator_name)
            return False
        cur.execute(
            """
            INSERT INTO elevator_events (time, elevator_id, floor, source)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT DO NOTHING
            """,
            (ts, row[0], floor, source),
        )
    conn.commit()
    return True


# ── Poll-Job (wird vom Scheduler aufgerufen) ──────────────────────────────────
def poll_source(source_cfg: dict, cb: CircuitBreaker, rate_limiter: RateLimiter) -> None:
    """
    Haupt-Poll-Logik für eine einzelne Quelle.
    Wird von APScheduler im Hintergrund-Thread aufgerufen.
    """
    name    = source_cfg["name"]
    url     = expand_env(source_cfg["url"])
    api_key = expand_env(source_cfg.get("api_key", ""))
    timeout = float(source_cfg.get("timeout_sec", 10.0))
    mapping = source_cfg.get("field_mapping", {})

    # Circuit Breaker prüfen
    if not cb.allow_request():
        log.warning("[%s] Circuit Breaker OPEN – Poll übersprungen.", name)
        POLL_ERRORS.labels(source=name, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(source=name).inc()
    rate_limiter.acquire()

    with POLL_DURATION.labels(source=name).time():
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/vnd.elevision.v1+json",
        } if api_key else {"Accept": "application/vnd.elevision.v1+json"}

        try:
            raw = fetch_with_retry(url, headers, timeout, name)
            if not raw:
                cb.record_failure()
                return

            records = map_response(raw, mapping)
            conn    = get_connection()
            now     = datetime.now(timezone.utc)
            ok_count = 0

            for record in records:
                ename = record["elevator_name"]
                floor = record["floor"]

                if insert_event(conn, ename, floor, now, "api"):
                    ok_count += 1
                    CURRENT_FLOOR.labels(elevator_name=ename).set(floor)
                    with _cache_lock:
                        _last_known.setdefault(name, {})[ename] = floor
                else:
                    push_to_dlq(conn, record, f"Unbekannter Aufzug: {ename}")

            refresh_dlq_metric(conn)
            cb.record_success()
            LAST_POLL_OK.labels(source=name).set(time.time())
            log.info("[%s] Poll OK – %d/%d Records.", name, ok_count, len(records))

            # Alerting-Schwelle: Warnung wenn alle Records fehlerhaft
            if records and ok_count == 0:
                log.error(
                    "[ALERT][%s] Alle %d Records abgelehnt – Feld-Mapping prüfen!",
                    name, len(records),
                )

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(source=name, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s] Alle Retry-Versuche erschöpft: %s", name, exc)
            _apply_cache_fallback(name)

        except httpx.HTTPStatusError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(source=name, error_type="http_error").inc()
            log.error("[%s] HTTP-Fehler %d: %s", name, exc.response.status_code, exc)

        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(source=name, error_type="unexpected").inc()
            log.exception("[%s] Unerwarteter Fehler: %s", name, exc)


def _apply_cache_fallback(source_name: str) -> None:
    """Gibt den letzten bekannten Wert aus dem Cache aus, falls vorhanden."""
    with _cache_lock:
        cached = dict(_last_known.get(source_name, {}))
    if cached:
        log.warning(
            "[%s] Fallback auf letzten Cache: %s",
            source_name,
            ", ".join(f"{k}=OG{v}" for k, v in cached.items()),
        )
        for ename, floor in cached.items():
            CURRENT_FLOOR.labels(elevator_name=ename).set(floor)
    else:
        log.warning("[%s] Kein Cache verfügbar – keine Fallback-Daten.", source_name)


# ── Health-Check & Metrics HTTP-Server ───────────────────────────────────────
_scheduler_running = False


class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args) -> None:  # HTTP-Access-Logs unterdrücken
        pass

    def do_GET(self) -> None:
        routes = {
            "/health":  self._health,
            "/ready":   self._ready,
            "/metrics": self._metrics,
        }
        handler = routes.get(self.path)
        if handler:
            handler()
        else:
            self._respond(404, "application/json", b'{"error":"not found"}')

    def _health(self) -> None:
        try:
            conn = get_connection()
            conn.cursor().execute("SELECT 1")
            body = b'{"status":"ok","db":"connected"}'
            code = 200
        except Exception as exc:
            body = json.dumps({"status": "degraded", "error": str(exc)}).encode()
            code = 503
        self._respond(code, "application/json", body)

    def _ready(self) -> None:
        if _scheduler_running:
            self._respond(200, "application/json", b'{"status":"ready"}')
        else:
            self._respond(503, "application/json", b'{"status":"not ready"}')

    def _metrics(self) -> None:
        self._respond(200, CONTENT_TYPE_LATEST, generate_latest(REGISTRY))

    def _respond(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ── Konfiguration laden ───────────────────────────────────────────────────────
def load_config(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(
            f"Config nicht gefunden: {path}. "
            "Erstelle poller_config.yaml (siehe Vorlage)."
        )
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


# ── Einstiegspunkt ────────────────────────────────────────────────────────────
def main() -> None:
    global _scheduler_running

    log.info("=== Elevator Poller (Produktionsmodus) ===")

    config  = load_config(CONFIG_PATH)
    sources = config.get("sources", [])

    if not sources:
        log.error("Keine Quellen in %s konfiguriert – Abbruch.", CONFIG_PATH)
        return

    log.info("Konfiguration geladen: %d Quelle(n) aus %s", len(sources), CONFIG_PATH)

    # HTTP-Server (Health + Metrics) in Daemon-Thread
    server = HTTPServer(("0.0.0.0", METRICS_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True, name="http-server").start()
    log.info("Health/Metrics-Server läuft auf Port %d", METRICS_PORT)
    log.info("  GET /health  → DB-Status")
    log.info("  GET /ready   → Scheduler-Status")
    log.info("  GET /metrics → Prometheus-Metriken")

    # Scheduler mit Berliner Zeitzone (APScheduler rechnet Trigger-Zeiten in UTC um)
    scheduler = BackgroundScheduler(timezone=BERLIN_TZ)

    for source in sources:
        interval = int(source.get("poll_interval_sec", 60))
        rps      = float(source.get("rate_limit_rps", 1.0))
        cb       = CircuitBreaker(name=source["name"])
        rl       = RateLimiter(rps=rps)

        scheduler.add_job(
            poll_source,
            trigger=IntervalTrigger(seconds=interval, timezone=BERLIN_TZ),
            args=[source, cb, rl],
            id=f"poll_{source['name']}",
            name=source["name"],
            next_run_time=datetime.now(BERLIN_TZ),  # sofort beim Start pollen
            max_instances=1,  # Verhindert überlappende Ausführung
            coalesce=True,    # Bei Rückstand: nur einmal ausführen, nicht aufholen
        )
        log.info(
            "  Job '%s': alle %ds, Rate-Limit %.1f req/s, "
            "CB-Schwelle %d Fehler, Timeout %ds",
            source["name"], interval, rps,
            CB_FAILURE_THRESHOLD, source.get("timeout_sec", 10),
        )

    scheduler.start()
    _scheduler_running = True
    log.info("Scheduler aktiv. Ctrl+C zum Beenden.")

    try:
        while True:
            time.sleep(30)
    except KeyboardInterrupt:
        log.info("Beende Poller …")
    finally:
        scheduler.shutdown(wait=False)
        server.shutdown()
        _scheduler_running = False
        log.info("Poller gestoppt.")


if __name__ == "__main__":
    main()

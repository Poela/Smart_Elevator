"""
Elevision Extended Poller
=========================
Ergaenzt api_poller.py um weitere Endpunkte der Elevision API:

  /publicapi/events/{id}/                   -> elevator_errors        (alle 5 min)
  /publicapi/controllers/{id}/conditions/doors -> elevator_door_stats (alle 10 min)
  /publicapi/controllers/{id}/statistics/count -> elevator_count_stats (stündlich)
  /publicapi/controllers/{id}/statistics/time  -> elevator_time_stats  (stündlich)
  /publicapi/controllers/{id}/overview         -> elevator_availability (minütlich)

Architektur-Ueberblick:
  +-----------------------------------------------------------------+
  |  APScheduler (BackgroundScheduler, TZ: Europe/Berlin)           |
  |  5 Jobs pro Controller aus poller_config.yaml                   |
  |    +- CircuitBreaker  (CLOSED -> OPEN -> HALF_OPEN, pro Ctrl.)  |
  |    +- RateLimiter     (Token-Bucket, max. 1 req/s pro Ctrl.)    |
  |    +- fetch()         (Tenacity Exp. Backoff 2 s -> 60 s)        |
  |    +- Transient/Perm. Fehlerklassifikation (401/403 vs 5xx)     |
  |    +- ON CONFLICT DO NOTHING (Idempotenz bei Doppelpoll)        |
  +-----------------------------------------------------------------+
  +-----------------------------------------------------------------+
  |  Prometheus-Metriken (:8081/metrics)                            |
  |    elevator_ext_poll_total       - Abfragen gesamt              |
  |    elevator_ext_poll_errors_total- Fehler nach Typ              |
  |    elevator_ext_poll_duration_s  - Dauer je Job-Typ             |
  |    elevator_ext_circuit_breaker  - CB-Status je Controller      |
  +-----------------------------------------------------------------+

Fehlerklassifikation:
  Transient:  HTTP 429/500/502/503/504, Netzwerk-Timeout
              -> Retry mit Exp. Backoff (max. 5 Versuche, 2->60 s)
  Permanent:  HTTP 401/403/404
              -> Kein Retry, CRITICAL-Log, CB bleibt offen

Idempotenz:  ON CONFLICT DO NOTHING auf den jeweiligen Unique-Indizes.
             Wiederholte Polls schreiben keinen doppelten Datensatz.

Konfiguration: poller_config.yaml (config-driven, kein Code-Change
               noetig um neue Controller hinzuzufuegen).

Starten: python elevision_extended_poller.py
"""

import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Optional

import httpx
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

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
log = logging.getLogger("elevator.extended")

BERLIN_TZ = pytz.timezone("Europe/Berlin")
METRICS_PORT = int(os.getenv("EXT_METRICS_PORT", "8081"))

# Circuit-Breaker-Schwellen (ueberschreibbar per Umgebungsvariable)
CB_FAILURE_THRESHOLD = int(os.getenv("CB_FAILURE_THRESHOLD", "5"))
CB_RECOVERY_TIMEOUT  = int(os.getenv("CB_RECOVERY_TIMEOUT_SEC", "60"))

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),
}

# ── Prometheus-Metriken ───────────────────────────────────────────────────────
POLL_TOTAL = Counter(
    "elevator_ext_poll_total",
    "Gesamtanzahl der Extended-Poller-Abfragen",
    ["controller", "job_type"],
)
POLL_ERRORS = Counter(
    "elevator_ext_poll_errors_total",
    "Fehlgeschlagene Abfragen nach Controller, Job-Typ und Fehlertyp",
    ["controller", "job_type", "error_type"],
)
POLL_DURATION = Histogram(
    "elevator_ext_poll_duration_seconds",
    "Dauer eines Poll-Zyklus in Sekunden",
    ["controller", "job_type"],
    buckets=[0.1, 0.5, 1.0, 2.5, 5.0, 15.0, 30.0],
)
CB_OPEN = Gauge(
    "elevator_ext_circuit_breaker_open",
    "Circuit-Breaker-Status: 1=OPEN, 0=CLOSED/HALF_OPEN",
    ["controller"],
)
LAST_POLL_OK = Gauge(
    "elevator_ext_last_successful_poll_unixtime",
    "Unix-Timestamp des letzten erfolgreichen Polls",
    ["controller", "job_type"],
)

# ── Circuit Breaker ───────────────────────────────────────────────────────────
class CBState(Enum):
    CLOSED    = auto()  # Normalbetrieb
    OPEN      = auto()  # Controller ausgefallen - keine Requests
    HALF_OPEN = auto()  # Erholungstest - ein Probe-Request erlaubt


@dataclass
class CircuitBreaker:
    """
    Zustandsbehafteter Circuit Breaker pro Controller.
    Alle Job-Typen eines Controllers teilen sich einen Breaker:
    haeuft ein Endpunkt Fehler an, werden alle Jobs pausiert.

    CB_FAILURE_THRESHOLD aufeinanderfolgende Fehler oeffnen den Breaker.
    Nach CB_RECOVERY_TIMEOUT Sekunden wechselt er in HALF_OPEN und
    laesst einen Probe-Request durch.
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
            CB_OPEN.labels(controller=self.name).set(0)

    def record_failure(self) -> None:
        with self._lock:
            self.failure_count += 1
            if self.failure_count >= self.threshold and self.state == CBState.CLOSED:
                self.state = CBState.OPEN
                self.opened_at = time.monotonic()
                CB_OPEN.labels(controller=self.name).set(1)
                log.error(
                    "[ALERT][%s] Circuit Breaker OPEN nach %d Fehlern - "
                    "alle Jobs pausiert fuer %ds.",
                    self.name, self.failure_count, self.recovery_timeout,
                )

    def allow_request(self) -> bool:
        with self._lock:
            if self.state == CBState.CLOSED:
                return True
            if self.state == CBState.OPEN:
                if time.monotonic() - self.opened_at >= self.recovery_timeout:
                    self.state = CBState.HALF_OPEN
                    log.info("[%s] Circuit Breaker -> HALF_OPEN (Probe-Request).", self.name)
                    return True
                return False
            return True  # HALF_OPEN: einen Test durchlassen


# ── Rate Limiter (Token Bucket) ───────────────────────────────────────────────
class RateLimiter:
    """
    Token-Bucket-Rate-Limiter (gemeinsam fuer alle Jobs eines Controllers).
    Verhindert, dass mehrere gleichzeitig laufende Jobs die API-Quelle
    ueberlasten (Fairness gegenueber der Quelle).
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


def get_conn() -> psycopg2.extensions.connection:
    conn: Optional[psycopg2.extensions.connection] = getattr(_thread_local, "conn", None)
    try:
        if conn is None or conn.closed:
            raise psycopg2.OperationalError
        conn.cursor().execute("SELECT 1")
    except psycopg2.Error:
        conn = psycopg2.connect(**DB_CONFIG)
        _thread_local.conn = conn
        log.info("DB-Verbindung hergestellt fuer Thread %s.", threading.current_thread().name)
    return conn


def expand_env(value: str) -> str:
    return re.sub(r"[$][{]([^}]+)[}]", lambda m: os.getenv(m.group(1), ""), str(value))


# ── HTTP-Abfrage mit Retry & Exponential Backoff ──────────────────────────────
_PERMANENT_STATUS = {401, 403, 404}
_TRANSIENT_STATUS = {429, 500, 502, 503, 504}


def fetch(url: str, token: str, params: dict = None, ctrl_name: str = "?", job: str = "?") -> Any:
    """
    HTTP GET mit Tenacity-Retry fuer transiente Fehler.

    Transient (HTTP 429/5xx, Netzwerk):
        Retry mit Exp. Backoff 2->60 s, max. 5 Versuche.
    Permanent (HTTP 401/403/404):
        Sofortiger Abbruch, CRITICAL-Log, kein Retry.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.elevision.v1+json",
    }

    @retry(
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=60),
        retry=retry_if_exception_type((httpx.RequestError, httpx.TimeoutException)),
        before_sleep=before_sleep_log(log, logging.WARNING),
        reraise=True,
    )
    def _do() -> Any:
        resp = httpx.get(url, headers=headers, params=params, timeout=15)
        if resp.status_code in _PERMANENT_STATUS:
            POLL_ERRORS.labels(controller=ctrl_name, job_type=job, error_type="permanent_http").inc()
            log.critical(
                "[PERMANENT][%s][%s] HTTP %d - kein Retry. Konfiguration pruefen.",
                ctrl_name, job, resp.status_code,
            )
            return None  # signalisiert: permanent fehlgeschlagen
        if resp.status_code in _TRANSIENT_STATUS:
            # Als transient klassifizieren -> Tenacity retried
            raise httpx.RequestError(f"Transient HTTP {resp.status_code}")
        resp.raise_for_status()
        return resp.json()

    return _do()


# ── DB-Hilfsfunktion ──────────────────────────────────────────────────────────
def elevator_id_by_name(conn, name: str) -> Optional[int]:
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM elevators WHERE name = %s", (name,))
        row = cur.fetchone()
    return row[0] if row else None


# ── Poll-Funktionen ───────────────────────────────────────────────────────────
def poll_availability(
    controller_id: int, db_name: str, base_url: str, token: str,
    cb: CircuitBreaker, rl: RateLimiter,
) -> None:
    """Verfuegbarkeits-Snapshot /overview (jede Minute)."""
    job = "availability"
    if not cb.allow_request():
        log.warning("[%s][%s] Circuit Breaker OPEN - uebersprungen.", db_name, job)
        POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(controller=db_name, job_type=job).inc()
    rl.acquire()

    with POLL_DURATION.labels(controller=db_name, job_type=job).time():
        try:
            data = fetch(f"{base_url}/publicapi/controllers/{controller_id}/overview",
                         token, ctrl_name=db_name, job=job)
            if data is None:
                cb.record_failure()
                return
            conn    = get_conn()
            elev_id = elevator_id_by_name(conn, db_name)
            if elev_id is None:
                log.warning("[%s][%s] Aufzug nicht in DB.", db_name, job)
                return
            avail   = data.get("availability") or {}
            running = data.get("running") or {}
            conn_st = data.get("connection") or {}
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO elevator_availability
                        (time, elevator_id, availability_pct, availability_level,
                         condition, operating_category, online)
                    VALUES (NOW(),%s,%s,%s,%s,%s,%s)
                """, (
                    elev_id,
                    avail.get("percentage"),
                    avail.get("availabilityLevel"),
                    data.get("condition"),
                    running.get("operatingCategory"),
                    conn_st.get("online"),
                ))
            conn.commit()
            cb.record_success()
            LAST_POLL_OK.labels(controller=db_name, job_type=job).set(time.time())
            log.info("[%s][%s] %.1f%% %s.",
                     db_name, job, avail.get("percentage", 0),
                     running.get("operatingCategory", "?"))

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s][%s] Alle Retry-Versuche erschoepft: %s", db_name, job, exc)
        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="unexpected").inc()
            log.exception("[%s][%s] Unerwarteter Fehler: %s", db_name, job, exc)


def poll_errors(
    controller_id: int, db_name: str, base_url: str, token: str,
    cb: CircuitBreaker, rl: RateLimiter,
) -> None:
    """Fehler-Events /events/{id}/ (alle 5 Minuten)."""
    job = "errors"
    if not cb.allow_request():
        log.warning("[%s][%s] Circuit Breaker OPEN - uebersprungen.", db_name, job)
        POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(controller=db_name, job_type=job).inc()
    rl.acquire()

    now   = datetime.now(timezone.utc)
    start = (now - timedelta(minutes=10)).isoformat()

    with POLL_DURATION.labels(controller=db_name, job_type=job).time():
        try:
            events = fetch(
                f"{base_url}/publicapi/events/{controller_id}/",
                token,
                {"startDate": start, "endDate": now.isoformat(), "type": "BOTH", "size": 1000},
                ctrl_name=db_name, job=job,
            )
            if events is None:
                cb.record_failure()
                return
            if not events:
                cb.record_success()
                return
            conn    = get_conn()
            elev_id = elevator_id_by_name(conn, db_name)
            if elev_id is None:
                log.warning("[%s][%s] Aufzug nicht in DB.", db_name, job)
                return
            inserted = 0
            with conn.cursor() as cur:
                for ev in events:
                    ts = ev.get("date")
                    if not ts:
                        continue
                    cur.execute("""
                        INSERT INTO elevator_errors
                            (time, elevator_id, api_event_id, event_type, category,
                             floor, pos_mm, e4_id, fst_id, details)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                        ON CONFLICT DO NOTHING
                    """, (
                        ts, elev_id,
                        ev.get("id"),
                        "ERROR" if ev.get("fstId") else "EVENT",
                        ev.get("category"),
                        ev.get("floor"),
                        ev.get("posMM"),
                        ev.get("e4Id"),
                        ev.get("fstId"),
                        json.dumps(ev.get("details") or {}),
                    ))
                    inserted += 1
            conn.commit()
            cb.record_success()
            LAST_POLL_OK.labels(controller=db_name, job_type=job).set(time.time())
            log.info("[%s][%s] %d Ereignisse gespeichert.", db_name, job, inserted)

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s][%s] Alle Retry-Versuche erschoepft: %s", db_name, job, exc)
        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="unexpected").inc()
            log.exception("[%s][%s] Unerwarteter Fehler: %s", db_name, job, exc)


def poll_door_conditions(
    controller_id: int, db_name: str, base_url: str, token: str,
    cb: CircuitBreaker, rl: RateLimiter,
) -> None:
    """Tuer-Konditionen /conditions/doors (alle 10 Minuten)."""
    job = "doors"
    if not cb.allow_request():
        log.warning("[%s][%s] Circuit Breaker OPEN - uebersprungen.", db_name, job)
        POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(controller=db_name, job_type=job).inc()
    rl.acquire()

    now   = datetime.now(timezone.utc)
    start = (now - timedelta(minutes=15)).isoformat()

    with POLL_DURATION.labels(controller=db_name, job_type=job).time():
        try:
            conditions = fetch(
                f"{base_url}/publicapi/controllers/{controller_id}/conditions/doors",
                token,
                {"startDate": start, "endDate": now.isoformat(), "size": 500},
                ctrl_name=db_name, job=job,
            )
            if conditions is None:
                cb.record_failure()
                return
            if not conditions:
                cb.record_success()
                return
            conn    = get_conn()
            elev_id = elevator_id_by_name(conn, db_name)
            if elev_id is None:
                return
            inserted = 0
            with conn.cursor() as cur:
                for cond in conditions:
                    ts    = cond.get("timestamp")
                    floor = cond.get("floor")
                    for door_key, dp in (cond.get("doorsPeriods") or {}).items():
                        avg   = dp.get("avg") or {}
                        cnt   = dp.get("count") or {}
                        photo = dp.get("photocell") or {}
                        cur.execute("""
                            INSERT INTO elevator_door_stats
                                (time, elevator_id, floor, door,
                                 avg_opening_ms, avg_closing_ms,
                                 reversing_count, cycles_count,
                                 photocell_activations, photocell_time_ms)
                            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                            ON CONFLICT DO NOTHING
                        """, (
                            ts, elev_id, floor, dp.get("door", door_key),
                            avg.get("openingTime"), avg.get("closingTime"),
                            cnt.get("reversing"), cnt.get("cycles"),
                            photo.get("activations"), photo.get("timeSpent"),
                        ))
                        inserted += 1
            conn.commit()
            cb.record_success()
            LAST_POLL_OK.labels(controller=db_name, job_type=job).set(time.time())
            log.info("[%s][%s] %d Tuer-Datensaetze gespeichert.", db_name, job, inserted)

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s][%s] Alle Retry-Versuche erschoepft: %s", db_name, job, exc)
        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="unexpected").inc()
            log.exception("[%s][%s] Unerwarteter Fehler: %s", db_name, job, exc)


def poll_count_stats(
    controller_id: int, db_name: str, base_url: str, token: str,
    cb: CircuitBreaker, rl: RateLimiter,
) -> None:
    """Zaehl-Statistiken /statistics/count (stuendlich)."""
    job = "count_stats"
    if not cb.allow_request():
        log.warning("[%s][%s] Circuit Breaker OPEN - uebersprungen.", db_name, job)
        POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(controller=db_name, job_type=job).inc()
    rl.acquire()

    now   = datetime.now(timezone.utc)
    start = (now - timedelta(hours=2)).isoformat()

    with POLL_DURATION.labels(controller=db_name, job_type=job).time():
        try:
            stats = fetch(
                f"{base_url}/publicapi/controllers/{controller_id}/statistics/count",
                token,
                {"startDate": start, "endDate": now.isoformat(), "size": 10},
                ctrl_name=db_name, job=job,
            )
            if stats is None:
                cb.record_failure()
                return
            if not stats:
                cb.record_success()
                return
            conn    = get_conn()
            elev_id = elevator_id_by_name(conn, db_name)
            if elev_id is None:
                return
            with conn.cursor() as cur:
                for s in stats:
                    cnt = s.get("count") or {}
                    avg = s.get("avg") or {}
                    cur.execute("""
                        INSERT INTO elevator_count_stats
                            (time, elevator_id,
                             car_calls, landing_calls, standard_drives, park_drives,
                             motor_start_up, motor_start_down, total_distance_mm,
                             avg_car_calls_main, avg_car_loading)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                        ON CONFLICT DO NOTHING
                    """, (
                        s.get("timestamp"), elev_id,
                        cnt.get("carCalls"), cnt.get("landingCalls"),
                        cnt.get("standardDrives"), cnt.get("parkDrives"),
                        cnt.get("motorStartUpwards"), cnt.get("motorStartDownwards"),
                        s.get("totalDistanceDriven"),
                        avg.get("carCallsLeavingMain"), avg.get("carLoading"),
                    ))
            conn.commit()
            cb.record_success()
            LAST_POLL_OK.labels(controller=db_name, job_type=job).set(time.time())
            log.info("[%s][%s] OK.", db_name, job)

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s][%s] Alle Retry-Versuche erschoepft: %s", db_name, job, exc)
        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="unexpected").inc()
            log.exception("[%s][%s] Unerwarteter Fehler: %s", db_name, job, exc)


def poll_time_stats(
    controller_id: int, db_name: str, base_url: str, token: str,
    cb: CircuitBreaker, rl: RateLimiter,
) -> None:
    """Zeit-Statistiken /statistics/time (stuendlich)."""
    job = "time_stats"
    if not cb.allow_request():
        log.warning("[%s][%s] Circuit Breaker OPEN - uebersprungen.", db_name, job)
        POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="circuit_open").inc()
        return

    POLL_TOTAL.labels(controller=db_name, job_type=job).inc()
    rl.acquire()

    now   = datetime.now(timezone.utc)
    start = (now - timedelta(hours=2)).isoformat()

    with POLL_DURATION.labels(controller=db_name, job_type=job).time():
        try:
            stats = fetch(
                f"{base_url}/publicapi/controllers/{controller_id}/statistics/time",
                token,
                {"startDate": start, "endDate": now.isoformat(), "size": 10},
                ctrl_name=db_name, job=job,
            )
            if stats is None:
                cb.record_failure()
                return
            if not stats:
                cb.record_success()
                return
            conn    = get_conn()
            elev_id = elevator_id_by_name(conn, db_name)
            if elev_id is None:
                return
            with conn.cursor() as cur:
                for s in stats:
                    t = s.get("time") or {}
                    cur.execute("""
                        INSERT INTO elevator_time_stats
                            (time, elevator_id,
                             drive_ms, idle_ms, drive_up_ms, drive_down_ms,
                             loading_ms, light_off_ms, esm_sleep_ms)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                        ON CONFLICT DO NOTHING
                    """, (
                        s.get("timestamp"), elev_id,
                        t.get("drive"), t.get("idle"),
                        t.get("driveUp"), t.get("driveDown"),
                        t.get("loading"), t.get("lightOff"), t.get("esmSleep"),
                    ))
            conn.commit()
            cb.record_success()
            LAST_POLL_OK.labels(controller=db_name, job_type=job).set(time.time())
            log.info("[%s][%s] OK.", db_name, job)

        except RetryError as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="retry_exhausted").inc()
            log.error("[ALERT][%s][%s] Alle Retry-Versuche erschoepft: %s", db_name, job, exc)
        except Exception as exc:
            cb.record_failure()
            POLL_ERRORS.labels(controller=db_name, job_type=job, error_type="unexpected").inc()
            log.exception("[%s][%s] Unerwarteter Fehler: %s", db_name, job, exc)


# ── Health-Check & Metrics HTTP-Server (:8081) ────────────────────────────────
_scheduler_running = False


class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args) -> None:
        pass  # HTTP-Access-Logs unterdruecken

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
            conn = get_conn()
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


# ── Konfiguration (config-driven, kein Code-Change fuer neue Controller) ──────
def load_controllers() -> list[dict]:
    """
    Liest alle Elevision-Controller aus poller_config.yaml.
    Neue Controller werden nur in der YAML-Datei eingetragen –
    kein Code-Change noetig (config-driven ingest).
    """
    config_path = os.getenv("POLLER_CONFIG", "config/poller_config.yaml")
    with open(config_path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    controllers = []
    for src in cfg.get("sources", []):
        url = expand_env(src.get("url", ""))
        m = re.search(r"/controllers/(\d+)$", url)
        if not m:
            continue  # kein Controller-Endpunkt -> ueberspringen
        base = re.sub(r"/publicapi.*", "", url)
        controllers.append({
            "id":       int(m.group(1)),
            "db_name":  src["field_mapping"].get("elevator_name_override") or src["name"],
            "base_url": base,
            "token":    expand_env(src.get("api_key", "")),
            "rps":      float(src.get("rate_limit_rps", 1.0)),
        })
    return controllers


# ── Hauptprogramm ─────────────────────────────────────────────────────────────
def main() -> None:
    global _scheduler_running

    log.info("=== Elevision Extended Poller ===")
    controllers = load_controllers()
    if not controllers:
        log.error("Keine Controller in poller_config.yaml gefunden.")
        return
    log.info("%d Controller geladen: %s",
             len(controllers), [c["db_name"] for c in controllers])

    # Health/Metrics HTTP-Server auf Port 8081 (api_poller belegt 8080)
    server = HTTPServer(("0.0.0.0", METRICS_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True, name="ext-http").start()
    log.info("Health/Metrics-Server laeuft auf Port %d", METRICS_PORT)
    log.info("  GET /health  -> DB-Status")
    log.info("  GET /ready   -> Scheduler-Status")
    log.info("  GET /metrics -> Prometheus-Metriken")

    scheduler = BackgroundScheduler(timezone=BERLIN_TZ)

    for c in controllers:
        # Ein CircuitBreaker und ein RateLimiter pro Controller
        # (alle Job-Typen teilen sich die Resilience-Ressource)
        cb = CircuitBreaker(name=c["db_name"])
        rl = RateLimiter(rps=c["rps"])
        args = (c["id"], c["db_name"], c["base_url"], c["token"], cb, rl)

        now = datetime.now(BERLIN_TZ)
        scheduler.add_job(poll_availability,    IntervalTrigger(seconds=60, timezone=BERLIN_TZ),
                          args=args, id=f"avail_{c['id']}",
                          max_instances=1, coalesce=True, next_run_time=now)
        scheduler.add_job(poll_errors,          IntervalTrigger(minutes=5, timezone=BERLIN_TZ),
                          args=args, id=f"errors_{c['id']}",
                          max_instances=1, coalesce=True, next_run_time=now)
        scheduler.add_job(poll_door_conditions, IntervalTrigger(minutes=10, timezone=BERLIN_TZ),
                          args=args, id=f"doors_{c['id']}",
                          max_instances=1, coalesce=True, next_run_time=now)
        scheduler.add_job(poll_count_stats,     IntervalTrigger(hours=1, timezone=BERLIN_TZ),
                          args=args, id=f"count_{c['id']}",
                          max_instances=1, coalesce=True, next_run_time=now)
        scheduler.add_job(poll_time_stats,      IntervalTrigger(hours=1, timezone=BERLIN_TZ),
                          args=args, id=f"tstat_{c['id']}",
                          max_instances=1, coalesce=True, next_run_time=now)

        log.info(
            "  %s (ID %d): avail=1min | errors=5min | doors=10min | stats=1h"
            " | CB-Schwelle=%d | Rate=%.1f req/s",
            c["db_name"], c["id"], CB_FAILURE_THRESHOLD, c["rps"],
        )

    scheduler.start()
    _scheduler_running = True
    log.info("Scheduler aktiv. Ctrl+C zum Beenden.")

    try:
        while True:
            time.sleep(30)
    except KeyboardInterrupt:
        log.info("Beende Extended Poller ...")
    finally:
        scheduler.shutdown(wait=False)
        server.shutdown()
        _scheduler_running = False
        log.info("Extended Poller gestoppt.")


if __name__ == "__main__":
    main()

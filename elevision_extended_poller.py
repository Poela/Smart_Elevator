"""
Elevision Extended Poller
=========================
Ergänzt api_poller.py um weitere Endpunkte:

  /publicapi/events/{id}/                   → elevator_errors        (alle 5 min)
  /publicapi/controllers/{id}/conditions/doors → elevator_door_stats (alle 10 min)
  /publicapi/controllers/{id}/statistics/count → elevator_count_stats (stündlich)
  /publicapi/controllers/{id}/statistics/time  → elevator_time_stats  (stündlich)
  /publicapi/controllers/{id}/overview         → elevator_availability (minütlich)

Starten: python elevision_extended_poller.py
"""

import json
import logging
import os
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import httpx
import psycopg2
import pytz
import yaml
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
log = logging.getLogger("elevator.extended")

BERLIN_TZ = pytz.timezone("Europe/Berlin")

DB_CONFIG = {
    "host":     os.getenv("DB_HOST", "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME", "elevator_db"),
    "user":     os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

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
    return conn


def expand_env(value: str) -> str:
    return re.sub(r"[$][{]([^}]+)[}]", lambda m: os.getenv(m.group(1), ""), str(value))


def get(url: str, token: str, params: dict = None) -> Any:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.elevision.v1+json",
    }
    resp = httpx.get(url, headers=headers, params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def elevator_id_by_name(conn, name: str) -> Optional[int]:
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM elevators WHERE name = %s", (name,))
        row = cur.fetchone()
    return row[0] if row else None


# ── Fehler-Events ─────────────────────────────────────────────────────────────
def poll_errors(controller_id: int, db_name: str, base_url: str, token: str) -> None:
    now   = datetime.now(timezone.utc)
    start = (now - timedelta(minutes=10)).isoformat()
    end   = now.isoformat()
    try:
        events = get(
            f"{base_url}/publicapi/events/{controller_id}/",
            token,
            {"startDate": start, "endDate": end, "type": "BOTH", "size": 1000},
        )
        if not events:
            return
        conn    = get_conn()
        elev_id = elevator_id_by_name(conn, db_name)
        if elev_id is None:
            log.warning("[errors] Aufzug '%s' nicht in DB.", db_name)
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
        log.info("[errors][%s] %d Ereignisse gespeichert.", db_name, inserted)
    except Exception as exc:
        log.error("[errors][%s] %s", db_name, exc)


# ── Tür-Konditionen ───────────────────────────────────────────────────────────
def poll_door_conditions(controller_id: int, db_name: str, base_url: str, token: str) -> None:
    now   = datetime.now(timezone.utc)
    start = (now - timedelta(minutes=15)).isoformat()
    try:
        conditions = get(
            f"{base_url}/publicapi/controllers/{controller_id}/conditions/doors",
            token,
            {"startDate": start, "endDate": now.isoformat(), "size": 500},
        )
        if not conditions:
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
        log.info("[doors][%s] %d Tür-Datensätze gespeichert.", db_name, inserted)
    except Exception as exc:
        log.error("[doors][%s] %s", db_name, exc)


# ── Zähl-Statistiken ─────────────────────────────────────────────────────────
def poll_count_stats(controller_id: int, db_name: str, base_url: str, token: str) -> None:
    now   = datetime.now(timezone.utc)
    start = (now - timedelta(hours=2)).isoformat()
    try:
        stats = get(
            f"{base_url}/publicapi/controllers/{controller_id}/statistics/count",
            token,
            {"startDate": start, "endDate": now.isoformat(), "size": 10},
        )
        if not stats:
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
        log.info("[count_stats][%s] OK.", db_name)
    except Exception as exc:
        log.error("[count_stats][%s] %s", db_name, exc)


# ── Zeit-Statistiken ─────────────────────────────────────────────────────────
def poll_time_stats(controller_id: int, db_name: str, base_url: str, token: str) -> None:
    now   = datetime.now(timezone.utc)
    start = (now - timedelta(hours=2)).isoformat()
    try:
        stats = get(
            f"{base_url}/publicapi/controllers/{controller_id}/statistics/time",
            token,
            {"startDate": start, "endDate": now.isoformat(), "size": 10},
        )
        if not stats:
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
        log.info("[time_stats][%s] OK.", db_name)
    except Exception as exc:
        log.error("[time_stats][%s] %s", db_name, exc)


# ── Verfügbarkeit ─────────────────────────────────────────────────────────────
def poll_availability(controller_id: int, db_name: str, base_url: str, token: str) -> None:
    try:
        data = get(f"{base_url}/publicapi/controllers/{controller_id}/overview", token)
        conn    = get_conn()
        elev_id = elevator_id_by_name(conn, db_name)
        if elev_id is None:
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
        log.info("[availability][%s] %.1f%% %s.",
                 db_name, avail.get("percentage", 0), running.get("operatingCategory", "?"))
    except Exception as exc:
        log.error("[availability][%s] %s", db_name, exc)


# ── Konfiguration ─────────────────────────────────────────────────────────────
def load_controllers() -> list[dict]:
    """Liest die Elevision-Controller aus poller_config.yaml."""
    with open("poller_config.yaml", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    controllers = []
    for src in cfg.get("sources", []):
        url = expand_env(src.get("url", ""))
        # Controller-ID aus URL extrahieren (z.B. .../controllers/242600)
        m = re.search(r"/controllers/(\d+)$", url)
        if not m:
            continue
        base = re.sub(r"/publicapi.*", "", url)
        controllers.append({
            "id":       int(m.group(1)),
            "db_name":  src["field_mapping"].get("elevator_name_override") or src["name"],
            "base_url": base,
            "token":    expand_env(src.get("api_key", "")),
        })
    return controllers


# ── Hauptprogramm ─────────────────────────────────────────────────────────────
def main() -> None:
    log.info("=== Elevision Extended Poller ===")
    controllers = load_controllers()
    if not controllers:
        log.error("Keine Controller in poller_config.yaml gefunden.")
        return
    log.info("%d Controller geladen: %s",
             len(controllers), [c["db_name"] for c in controllers])

    scheduler = BackgroundScheduler(timezone=BERLIN_TZ)

    for c in controllers:
        args = (c["id"], c["db_name"], c["base_url"], c["token"])

        scheduler.add_job(poll_availability,   IntervalTrigger(seconds=60),   args=args,
                          id=f"avail_{c['id']}",  max_instances=1, coalesce=True)
        scheduler.add_job(poll_errors,         IntervalTrigger(minutes=5),    args=args,
                          id=f"errors_{c['id']}", max_instances=1, coalesce=True)
        scheduler.add_job(poll_door_conditions,IntervalTrigger(minutes=10),   args=args,
                          id=f"doors_{c['id']}",  max_instances=1, coalesce=True)
        scheduler.add_job(poll_count_stats,    IntervalTrigger(hours=1),      args=args,
                          id=f"count_{c['id']}",  max_instances=1, coalesce=True)
        scheduler.add_job(poll_time_stats,     IntervalTrigger(hours=1),      args=args,
                          id=f"tstat_{c['id']}",  max_instances=1, coalesce=True)

        log.info("  %s (ID %d): Verfügbarkeit 1min | Fehler 5min | Türen 10min | Stats 1h",
                 c["db_name"], c["id"])

    scheduler.start()
    log.info("Scheduler läuft. Ctrl+C zum Beenden.")
    try:
        while True:
            time.sleep(30)
    except KeyboardInterrupt:
        pass
    finally:
        scheduler.shutdown(wait=False)
        log.info("Extended Poller gestoppt.")


if __name__ == "__main__":
    main()

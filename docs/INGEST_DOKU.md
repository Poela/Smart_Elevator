# Projektdokumentation – Ingest-Lead & Google Cloud
## Smart Elevator Monitoring – Datenbanken 2 (DHBW)

> Diese Datei erklärt, **was** implementiert wurde, **womit** es gebaut wurde und **wie** es die Anforderungen der Aufgabenstellung erfüllt.  
> Zielgruppe: Ingest-Lead-Präsentation + Prüfungsvorbereitung.

---

## Inhaltsverzeichnis

1. [Überblick: Was ist der Ingest-Service?](#1-überblick)
2. [Architektur & Komponenten](#2-architektur--komponenten)
3. [Anforderungserfüllung im Detail](#3-anforderungserfüllung-im-detail)
   - [Scheduling-Konzept](#31-scheduling-konzept)
   - [Fallback-Strategien](#32-fallback-strategien)
   - [Error Handling](#33-error-handling)
   - [Rate-Limiting & Fairness](#34-rate-limiting--fairness)
   - [Konfiguration ohne Code-Änderung](#35-konfiguration-ohne-code-änderung)
   - [Observability / Metriken / Health-Checks](#36-observability--metriken--health-checks)
   - [Idempotenz](#37-idempotenz)
4. [Ingest-Pipeline: Alle Stufen](#4-ingest-pipeline-alle-stufen)
5. [Google Cloud Implementation](#5-google-cloud-implementation)
   - [Welche GCP-Dienste werden genutzt?](#51-welche-gcp-dienste-werden-genutzt)
   - [Deployment-Ablauf (gcp-deploy.ps1)](#52-deployment-ablauf-gcp-deployps1)
   - [Cloud Run Services](#53-cloud-run-services)
   - [Cloud Run Jobs + Cloud Scheduler](#54-cloud-run-jobs--cloud-scheduler)
   - [Cloud SQL (PostgreSQL)](#55-cloud-sql-postgresql)
   - [Kosten & Free-Tier](#56-kosten--free-tier)
6. [Codeübersicht der Kern-Dateien](#6-codeübersicht-der-kern-dateien)
7. [Was du in der Präsentation erklären musst](#7-was-du-in-der-präsentation-erklären-musst)

---

## 1. Überblick

Der Ingest-Service ist die erste Stufe der Datenpipeline. Er holt zuverlässig Daten aus externen Quellen und schreibt sie in die Datenbank – ohne Duplikate, ohne Datenverlust, auch wenn die API kurzzeitig ausfällt.

**Datenquellen:**
| Quelle | Was wird geholt? | Datei |
|--------|-----------------|-------|
| Elevision REST-API | Aktueller Stockwerk-Stand (Echtzeit) | `api_poller.py` |
| Elevision REST-API (erweitert) | Fehler, Türstatus, Statistiken, Verfügbarkeit | `elevision_extended_poller.py` |
| DWD WarnWetter-API | Wetter Öhringen (Temperatur, Regen, Wind) | `dwd_poller.py` |
| DWD OpenData (FTP) | Historische Wetterdaten seit 1947 | `dwd_history_importer.py` |
| CSV-Dateien | Historische Aufzugsbewegungen | `csv_importer.py` |

---

## 2. Architektur & Komponenten

```
┌─────────────────────────────────────────────────────────────────┐
│                        INGEST LAYER                             │
│                                                                 │
│  ┌──────────────┐  ┌──────────────────┐  ┌────────────────┐   │
│  │ api_poller   │  │ extended_poller  │  │  dwd_poller    │   │
│  │ (60s Takt)   │  │ (1-60 min Takt)  │  │  (stündlich)   │   │
│  └──────┬───────┘  └────────┬─────────┘  └───────┬────────┘   │
│         │                   │                     │            │
│  ┌──────▼───────────────────▼─────────────────────▼────────┐  │
│  │              APScheduler (Europe/Berlin)                 │  │
│  │              + Tenacity Retry + Circuit Breaker          │  │
│  └──────────────────────────┬────────────────────────────┘  │
│                             │                                   │
│  ┌──────────────────────────▼────────────────────────────┐    │
│  │          PostgreSQL / TimescaleDB (Hypertable)         │    │
│  │          ON CONFLICT DO NOTHING (Idempotenz)           │    │
│  └───────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

**Technologie-Stack:**
| Aufgabe | Technologie | Warum |
|---------|-------------|-------|
| HTTP-Requests | `httpx` | Async-fähig, modernes API, Timeout-Support |
| Scheduling | `APScheduler` | DST-aware, BackgroundScheduler, CronTrigger |
| Retry-Logik | `tenacity` | Dekorator-basiert, exponentieller Backoff, konfigurierbar |
| Datenbank | `psycopg2` | PostgreSQL-native, `execute_values()` für Bulk-Inserts |
| Metriken | `prometheus_client` | Standardformat, Grafana-kompatibel |
| Config | `PyYAML` + `.env` | Konfigurierbar ohne Code-Änderung |

---

## 3. Anforderungserfüllung im Detail

### 3.1 Scheduling-Konzept

**Anforderung:** Intervalle, Zeitzonen, Sommerzeit

**Implementierung in `api_poller.py`:**

```python
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.cron import CronTrigger
import pytz

BERLIN_TZ = pytz.timezone("Europe/Berlin")

scheduler = BackgroundScheduler(timezone=BERLIN_TZ)

# Kontinuierlicher Poller: alle 60 Sekunden
scheduler.add_job(
    poll_all_sources,
    trigger=IntervalTrigger(seconds=60),
    timezone=BERLIN_TZ,
    max_instances=1,        # verhindert parallele Ausführung
    coalesce=True,          # überspringt verpasste Läufe statt aufzuholen
    next_run_time=datetime.now(BERLIN_TZ)  # startet sofort beim Hochfahren
)

# Tägliche Jobs (Forecast, Alerter) mit CronTrigger
scheduler.add_job(
    run_forecast,
    trigger=CronTrigger(hour=2, minute=0, timezone=BERLIN_TZ)
)
```

**Wie werden Zeitzonen und Sommerzeit behandelt?**
- Alle Timestamps werden **intern als UTC** gespeichert (`TIMESTAMPTZ` in PostgreSQL)
- Der Scheduler läuft in `Europe/Berlin` → CronJob „täglich 02:00 Uhr" bleibt immer 02:00 Ortszeit, egal ob Sommer- oder Winterzeit
- `coalesce=True` verhindert, dass nach einem Server-Ausfall alle verpassten Läufe nachgeholt werden (nur einmal ausführen, dann weiter)
- `max_instances=1` verhindert, dass ein langsamer Poll-Aufruf und der nächste Intervall überlappen

---

### 3.2 Fallback-Strategien

**Anforderung:** Retry, Backoff, Circuit Breaker, DLQ, Caching

#### Retry + Exponentieller Backoff (Tenacity)

```python
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

@retry(
    stop=stop_after_attempt(5),
    wait=wait_exponential(multiplier=1, min=2, max=60),
    retry=retry_if_exception_type((httpx.RequestError, httpx.TimeoutException)),
    before_sleep=before_sleep_log(log, logging.WARNING),
    reraise=True,
)
async def fetch_source(url: str) -> dict:
    response = await client.get(url, timeout=10.0)
    response.raise_for_status()
    return response.json()
```

**Backoff-Zeiten:** 2s → 4s → 8s → 16s → 32s → 60s (nach 5 Versuchen: Fehler wird weitergegeben)

#### Circuit Breaker (3 Zustände)

Der Circuit Breaker ist in `api_poller.py` und `elevision_extended_poller.py` selbst implementiert:

```
CLOSED ──► (5 Fehler in Folge) ──► OPEN ──► (60s warten) ──► HALF_OPEN
  ▲                                                                │
  └──────────────────── (1 erfolgreicher Request) ────────────────┘
```

| Zustand | Bedeutung | Verhalten |
|---------|-----------|-----------|
| **CLOSED** | Normal | Alle Requests werden durchgelassen |
| **OPEN** | Zu viele Fehler | Requests werden BLOCKIERT (sofort Fehler) |
| **HALF_OPEN** | Recovery-Test | Ein Probe-Request; Erfolg → CLOSED, Fehler → OPEN |

**Konfigurierbar:**
- `CB_FAILURE_THRESHOLD = 5` (nach 5 Fehlern → OPEN)
- `CB_RECOVERY_TIMEOUT_SEC = 60` (60s warten vor HALF_OPEN)

**Warum Circuit Breaker?** Ohne CB würde der Service bei einer ausgefallenen API alle 60s einen Request machen, der immer scheitert. Mit CB werden diese sinnlosen Requests unterdrückt und der externe Dienst entlastet.

#### Dead-Letter Queue (DLQ)

Wenn ein Datensatz nach allen Retries nicht in die Datenbank geschrieben werden kann, landet er in der `elevator_events_dlq`-Tabelle:

```sql
CREATE TABLE elevator_events_dlq (
    id          SERIAL PRIMARY KEY,
    payload     JSON NOT NULL,
    error_msg   TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ  -- NULL = noch nicht bearbeitet
);
```

- Kein Datenverlust auch bei temporären DB-Fehlern
- Manuelles Replay möglich via `UPDATE elevator_events_dlq SET resolved_at = NOW() WHERE id = ...`
- Prometheus-Metrik `elevator_dlq_size_total` zeigt wie viele ungelöste Einträge vorhanden sind

#### Last-Value Cache Fallback

```python
_last_known: dict[str, dict[str, int]] = {}  # source_name → elevator_name → floor

# Nach erfolgreichem Poll:
_last_known[source_name][elevator_name] = floor

# Bei API-Fehler nach allen Retries:
cached_floor = _last_known.get(source_name, {}).get(elevator_name)
if cached_floor is not None:
    log.warning(f"API failed, using cached floor {cached_floor}")
    FLOOR_GAUGE.labels(elevator=elevator_name).set(cached_floor)
```

Der Cache hält den letzten bekannten Stockwerk-Stand im Arbeitsspeicher. Bei API-Ausfall werden Prometheus-Metriken (und damit Grafana-Dashboards) mit dem letzten bekannten Wert befüllt statt leer zu bleiben.

---

### 3.3 Error Handling

**Anforderung:** transient vs. permanent, Logging, Alerting, Idempotenz

#### Fehlerklassifikation

| HTTP-Status | Typ | Reaktion |
|-------------|-----|----------|
| 429 (Rate Limited) | Transient | Retry mit Backoff |
| 500–504 (Server Error) | Transient | Retry mit Backoff |
| 401 (Unauthorized) | Permanent | KEIN Retry, `log.critical()` |
| 403 (Forbidden) | Permanent | KEIN Retry, `log.critical()` |
| 404 (Not Found) | Permanent | KEIN Retry, `log.critical()` |
| Netzwerk-Timeout | Transient | Retry mit Backoff |

```python
try:
    response = await client.get(url)
    if response.status_code in (401, 403, 404):
        log.critical(f"Permanent error {response.status_code} for {url} – no retry")
        return None  # Circuit Breaker wird NICHT ausgelöst (kein Infra-Problem)
    response.raise_for_status()  # 4xx/5xx → Exception → Tenacity Retry
except httpx.TimeoutException:
    log.warning(f"Timeout for {url}")
    raise  # → Tenacity nimmt den Retry auf
```

#### Logging-Level-Strategie

| Level | Wann |
|-------|------|
| `DEBUG` | Einzelne Poll-Ergebnisse (nur bei LOG_LEVEL=DEBUG) |
| `INFO` | Erfolgreiche Inserts, Scheduler-Start |
| `WARNING` | Retry-Versuch, Cache-Fallback aktiv |
| `ERROR` | Alle Retries ausgeschöpft, Circuit Breaker öffnet |
| `CRITICAL` | Permanente API-Fehler (401, 403), DB-Verbindung komplett ausgefallen |

---

### 3.4 Rate-Limiting & Fairness

**Anforderung:** Rate-Limiting & Fairness gegenüber der API

**Token-Bucket-Implementierung in `api_poller.py`:**

```python
class TokenBucket:
    def __init__(self, rate_rps: float):
        self.rate = rate_rps
        self.tokens = rate_rps
        self.last_refill = time.monotonic()

    def consume(self) -> bool:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.rate, self.tokens + elapsed * self.rate)
        self.last_refill = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False  # → Anfrage wird verzögert/übersprungen
```

**Konfiguriert via `poller_config.yaml`:**
```yaml
sources:
  - name: "Aufzug West"
    rate_limit_rps: 1.0  # max 1 Request pro Sekunde
```

Jede Datenquelle hat ihren eigenen Token-Bucket. Dadurch werden verschiedene API-Endpunkte unabhängig voneinander rate-limited (Fairness).

---

### 3.5 Konfiguration ohne Code-Änderung

**Anforderung:** Neue Endpunkte ohne Code-Änderung hinzufügen

**`poller_config.yaml` – der zentrale Konfigurationspunkt:**

```yaml
sources:
  - name: "Campus Brücken HN West beim L Bau"
    url: "${ELEVISION_API_BASE}/publicapi/controllers/242600"
    api_key: "${ELEVISION_JWT_TOKEN}"
    poll_interval_sec: 60
    timeout_sec: 10
    rate_limit_rps: 1.0
    field_mapping:
      elevator_name: "name"
      elevator_name_override: "Campus Brücken HN West"
      floor: "liftStatus.car.floor"   # Dot-Notation für verschachteltes JSON
```

**Was `field_mapping` kann:**
- Dot-Notation: `liftStatus.car.floor` → navigiert verschachteltes JSON
- `elevator_name_override`: überschreibt den Namen aus der API (z.B. wenn die API lange interne Namen liefert)

**Umgebungsvariablen im YAML:**
```python
def expand_env(text: str) -> str:
    return re.sub(r'\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), ''), text)
```

→ `${ELEVISION_API_BASE}` wird beim Laden aus `.env` expandiert.

**Um einen neuen Aufzug hinzuzufügen:**
1. Neuen Block in `poller_config.yaml` hinzufügen
2. Service neu starten
3. Kein Python-Code ändern

---

### 3.6 Observability / Metriken / Health-Checks

**Anforderung:** Metriken, Health-Checks, Alerting

Jeder Poller-Service startet einen eingebetteten HTTP-Server (kein Flask/FastAPI nötig – reines `http.server`-Modul):

| Port | Service | Endpoints |
|------|---------|-----------|
| 8080 | api_poller | `/health`, `/ready`, `/metrics` |
| 8081 | extended_poller | `/health`, `/ready`, `/metrics` |
| 8082 | anomaly_alerter | `/health`, `/metrics` |

**Health-Check (`/health`):**
```python
# GET /health → prüft DB-Verbindung
try:
    conn = psycopg2.connect(...)
    conn.close()
    return 200, '{"status": "ok"}'
except Exception as e:
    return 503, f'{{"status": "error", "detail": "{e}"}}'
```

Wird von Cloud Run automatisch genutzt: Wenn `/health` 503 zurückgibt, startet Cloud Run den Container neu.

**Readiness-Check (`/ready`):**
```python
# GET /ready → prüft ob der Scheduler läuft
if scheduler.running:
    return 200, '{"status": "ready"}'
else:
    return 503, '{"status": "not_ready", "detail": "scheduler not running"}'
```

**Prometheus-Metriken (`/metrics`):**
```
# HELP elevator_poll_total Total number of polls per source
# TYPE elevator_poll_total counter
elevator_poll_total{source="Campus Brücken HN West"} 1423.0

# HELP elevator_poll_errors_total Total errors per source and type  
elevator_poll_errors_total{source="Campus Brücken HN West", error_type="timeout"} 3.0

# HELP elevator_circuit_breaker_open Circuit breaker state (1=open)
elevator_circuit_breaker_open{source="Campus Brücken HN West"} 0.0

# HELP elevator_dlq_size_total Unresolved DLQ entries
elevator_dlq_size_total 0.0

# HELP elevator_last_successful_poll_unixtime Unix timestamp of last success
elevator_last_successful_poll_unixtime{source="Campus Brücken HN West"} 1716195600.0
```

Diese Metriken werden von Grafana per Prometheus-Datasource abgerufen und können Alerting-Regeln auslösen (z.B. „Circuit Breaker seit 10 Minuten offen" → Slack-Benachrichtigung).

---

### 3.7 Idempotenz

**Anforderung:** Idempotenz (mehrfaches Ausführen = gleiches Ergebnis)

**Problem ohne Idempotenz:** Wenn der Service 10 Minuten nicht lief und dann wieder startet und zweimal denselben Datenpunkt abholt, entstehen Duplikate in der Datenbank.

**Lösung: `ON CONFLICT DO NOTHING` auf UNIQUE-Constraint:**

```sql
-- Schema: Unique-Constraint verhindert Duplikate
ALTER TABLE elevator_events ADD CONSTRAINT uq_event UNIQUE (time, elevator_id);

-- Insert: Duplikate werden stillschweigend ignoriert
INSERT INTO elevator_events (time, elevator_id, floor, source)
VALUES (%s, %s, %s, %s)
ON CONFLICT DO NOTHING;
```

- Derselbe Datenpunkt kann beliebig oft gesendet werden → nur beim ersten Mal gespeichert
- Kein verteiltes Locking nötig
- Bei Wetterdaten: `ON CONFLICT DO UPDATE` (neueste DWD-Vorhersage überschreibt alte)

---

## 4. Ingest-Pipeline: Alle Stufen

| # | Stufe | Service | Frequenz | Quelle | Ziel |
|---|-------|---------|----------|--------|------|
| 1 | Historical Import | `csv_importer.py` | Einmalig | CSV-Dateien | `elevator_events` |
| 2 | Echtzeit-Poll | `api_poller.py` | Alle 60s | Elevision API | `elevator_events` |
| 3 | Extended Poll | `elevision_extended_poller.py` | 1–60 min | Elevision API | `elevator_errors`, `elevator_door_stats`, `elevator_availability`, ... |
| 4 | Wetter (aktuell) | `dwd_poller.py` | Stündlich | DWD WarnWetter-API | `weather_observations`, `weather_hourly` |
| 5 | Wetter (historisch) | `dwd_history_importer.py` | Einmalig | DWD OpenData | `weather_observations` (ab 1947) |
| 6 | Forecast | `forecast_service.py` | Täglich 02:00 UTC | DB → LightGBM | `elevator_forecast` |
| 7 | Anomalie-Alerter | `anomaly_alerter.py` | Täglich 07:00 UTC | DB View | `alert_log` |

---

## 5. Google Cloud Implementation

### 5.1 Welche GCP-Dienste werden genutzt?

| GCP-Dienst | Lokal entspricht | Zweck im Projekt |
|------------|-----------------|-----------------|
| **Cloud Run** | `docker run` | Serverless Container für dauerhaft laufende Services (Poller, Grafana) |
| **Cloud Run Jobs** | Cron-Job mit Docker | Für einmalig/täglich laufende Services (Forecast, Alerter, DWD) |
| **Cloud SQL (PostgreSQL 16)** | `docker-compose` TimescaleDB | Verwaltete relationale Datenbank |
| **Cloud Scheduler** | Cron-Daemon (Linux) | Plant wann welcher Cloud Run Job startet |
| **Secret Manager** | `.env`-Datei | Sichere Speicherung von Passwörtern / API-Keys |

### 5.2 Deployment-Ablauf (`gcp-deploy.ps1`)

Das Skript automatisiert den **gesamten** Deployment-Prozess in einem einzigen Durchlauf.

**Schritt 1: GCP APIs aktivieren**
```powershell
gcloud services enable `
    run.googleapis.com `
    sqladmin.googleapis.com `
    cloudscheduler.googleapis.com `
    secretmanager.googleapis.com `
    --project $PROJECT_ID
```

Ohne diese Aktivierung kann man die Dienste nicht nutzen, auch wenn sie im Projekt existieren.

**Schritt 2: Cloud SQL Instanz anlegen**
```powershell
gcloud sql instances create $SQL_INSTANCE `
    --database-version=POSTGRES_16 `
    --tier=db-f1-micro `           # Kleinste (günstigste) Instanz
    --region=$REGION `
    --storage-size=10GB `
    --storage-type=SSD `
    --backup-start-time=02:00 `    # Automatisches Backup täglich um 02:00 UTC
    --project $PROJECT_ID
```

**Schritt 3: Datenbank und User anlegen**
```powershell
gcloud sql databases create $DB_NAME --instance=$SQL_INSTANCE
gcloud sql users create $DB_USER --instance=$SQL_INSTANCE --password=$DB_PASSWORD
```

**Schritt 4: Schema einspielen**
```powershell
# Verbindung über Cloud SQL Auth Proxy (sicherer Tunnel ohne public IP nötig)
psql "host=127.0.0.1 port=5433 dbname=$DB_NAME user=$DB_USER password=$DB_PASSWORD" `
    -f schema-gcp.sql
```

**Schritt 5: Docker Image bauen und pushen**
```powershell
# Für Cloud Run muss das Image für linux/amd64 gebaut werden
docker buildx build --platform linux/amd64 -t hiprabbit/smart-elevator:latest --push .
```

**Schritt 6: Cloud Run Services deployen**
```powershell
# api_poller als dauerhaft laufender Service
gcloud run deploy api-poller `
    --image docker.io/hiprabbit/smart-elevator:latest `
    --command python --args api_poller.py `
    --region $REGION `
    --no-allow-unauthenticated `  # Nur intern erreichbar
    --min-instances 1 `           # Immer mind. 1 Instanz → keine Cold-Starts
    --cpu 1 --memory 512Mi `
    --no-cpu-throttle `           # CPU nicht drosseln wenn idle (wichtig für Scheduler)
    --set-env-vars "DB_HOST=...,ELEVISION_JWT_TOKEN=..." `
    --project $PROJECT_ID
```

---

### 5.3 Cloud Run Services

Dauerhaft laufende Container (werden nicht beendet, verarbeiten kontinuierlich):

| Service Name | Datei | Ports | Warum Cloud Run? |
|-------------|-------|-------|-----------------|
| `grafana` | Grafana-Image | 3000 (public) | Stateless, skalierbar, kein Server-Management |
| `api-poller` | `api_poller.py` | 8080 (privat) | Läuft 24/7, braucht konstante CPU für APScheduler |
| `extended-poller` | `elevision_extended_poller.py` | 8081 (privat) | Wie api-poller |

**Wichtig: `--no-cpu-throttle`**  
Cloud Run drosselt normalerweise die CPU wenn kein HTTP-Request reinkommt. Da der Poller-Service seinen Scheduler intern laufen lässt (kein eingehender HTTP-Traffic), muss CPU-Throttling deaktiviert werden – sonst schläft der Scheduler ein.

**Wichtig: `--min-instances 1`**  
Verhindert, dass Cloud Run den Container auf 0 Instanzen skaliert (Cold Start). Ein Poller-Service der nicht läuft sammelt keine Daten.

---

### 5.4 Cloud Run Jobs + Cloud Scheduler

Für Services die nicht dauerhaft laufen, sondern einmal täglich/stündlich:

```powershell
# Cloud Run Job definieren (beschreibt NUR wie der Container laufen soll)
gcloud run jobs create dwd-poller-job `
    --image docker.io/hiprabbit/smart-elevator:latest `
    --command python --args "dwd_poller.py" `
    --region $REGION `
    --max-retries 2 `       # Bei Fehler: max. 2 Wiederholungen
    --task-timeout 300s `   # Timeout nach 5 Minuten
    --project $PROJECT_ID

# Cloud Scheduler plant wann der Job startet
gcloud scheduler jobs create http dwd-poller-schedule `
    --schedule="0 * * * *" `     # Jede volle Stunde (Cron-Syntax)
    --uri="https://run.googleapis.com/v1/namespaces/.../jobs/dwd-poller-job:run" `
    --http-method=POST `
    --oidc-service-account-email="..." `  # Authentifizierung via Service Account
    --location=$REGION `
    --project $PROJECT_ID
```

| Job Name | Schedule | Timeout | Bedeutung |
|----------|----------|---------|-----------|
| `dwd-poller-job` | `0 * * * *` | 300s | Wetter stündlich |
| `forecast-job` | `0 2 * * *` | 1800s | ML-Forecast täglich 02:00 UTC |
| `alerter-job` | `0 7 * * *` | 600s | Anomalie-Check täglich 07:00 UTC |

**Vorteil gegenüber dauerhaftem Service:**  
Ein forecast_service der täglich 10 Minuten läuft, braucht keinen dauerhaften Container. Cloud Run Jobs starten, führen die Aufgabe aus, und beenden sich dann – du zahlst nur für die Laufzeit.

---

### 5.5 Cloud SQL (PostgreSQL)

**Warum Cloud SQL statt selbst-gehostetes PostgreSQL auf einer VM?**

| Aspekt | Cloud SQL | Selbst-gehostetes PostgreSQL |
|--------|-----------|------------------------------|
| Updates/Patches | Automatisch | Manuell |
| Backups | Konfigurierbar, automatisch | Selbst einrichten |
| Ausfallsicherheit | Managed, Multi-Zone möglich | Selbst konfigurieren |
| Skalierung | Tier wechseln (Klick) | VM vergrößern, Migration |
| Kosten | ~$10/Monat (db-f1-micro) | VM-Kosten + Zeit |

**Verbindungssicherheit:**
- Cloud Run Services verbinden sich über den **Cloud SQL Auth Proxy** – ein Sidecar-Prozess der eine sichere, verschlüsselte Verbindung ohne öffentliche IP ermöglicht
- Connection String in Cloud Run: `host=/cloudsql/PROJECT:REGION:INSTANCE` (Unix Socket)
- `DB_SSLMODE=require` als Umgebungsvariable

**Instanz-Konfiguration:**
```
Typ:          db-f1-micro (1 vCPU shared, 614 MB RAM)
Speicher:     10 GB SSD
PostgreSQL:   Version 16
Backup:       Täglich 02:00 UTC, 7 Tage Aufbewahrung
Region:       us-central1
```

---

### 5.6 Kosten & Free-Tier

Das Projekt nutzt den **Google Cloud Free Trial ($300 Guthaben)**:

| Dienst | Monatliche Kosten |
|--------|------------------|
| Cloud SQL (db-f1-micro) | ~$10 |
| Cloud Run Services (3x, min 1 Instanz) | ~$4–6 |
| Cloud Run Jobs (3x, kurze Laufzeiten) | < $0.50 |
| Container Registry / Docker Hub | $0 (Docker Hub Free Tier) |
| **Gesamt** | **~$15–20/Monat** |

Mit $300 Free-Trial: **15–20 Monate Laufzeit**.

---

## 6. Codeübersicht der Kern-Dateien

| Datei | Rolle | Kernkonzepte |
|-------|-------|-------------|
| `api_poller.py` | Hauptpoller (Echtzeit) | APScheduler, Circuit Breaker, Tenacity, DLQ, Token Bucket, Prometheus |
| `elevision_extended_poller.py` | Erweiterter Poller | Gleiche Architektur wie api_poller, andere Endpunkte |
| `dwd_poller.py` | Wetter-Poller | Tenacity Retry, DWD-API Parsing (Zehntel-Skalierung), stündlicher Loop |
| `dwd_history_importer.py` | Historischer Wetter-Import | Bulk-Download DWD FTP, Sentinel-Wert-Bereinigung (-999) |
| `csv_importer.py` | Einmaliger CSV-Import | Batch-Insert mit `execute_values()`, quality_flag Berechnung |
| `forecast_service.py` | ML-Forecast | LightGBM Quantile Regression, Lag-Features, Holdout-Evaluation |
| `anomaly_alerter.py` | Anomalie-Erkennung | Z-Score auf DB-View, Alert-Log, Prometheus |
| `poller_config.yaml` | Konfiguration | Alle Endpunkte, Intervalle, Rate-Limits ohne Code-Änderung |
| `schema.sql` | Datenbankschema | TimescaleDB Hypertable, JSONB-Attribute, Unique-Constraints |
| `schema-gcp.sql` | Schema für Cloud SQL | Wie schema.sql, Cloud SQL kompatibel |
| `gcp-deploy.ps1` | GCP-Deployment | Vollautomatisiertes Deployment aller Services auf GCP |
| `docker-compose.yml` | Lokale Entwicklung | TimescaleDB + Grafana lokal |

---

## 7. Was du in der Präsentation erklären musst

Als **Ingest-Lead** bist du für folgende Themen verantwortlich:

### Pflicht-Erklärungen (werden sicher gefragt):

**1. Warum APScheduler und nicht Cron?**  
→ APScheduler läuft im Python-Prozess, ist DST-aware, erlaubt `max_instances=1` und kann dynamisch zur Laufzeit Jobs hinzufügen/entfernen. System-Cron kennt den Python-Kontext nicht.

**2. Was passiert wenn die Elevision-API 5 Minuten nicht erreichbar ist?**  
→ Tenacity versucht max. 5x mit exponentiellem Backoff (bis zu 60s). Nach dem 5. Fehlschlag öffnet der Circuit Breaker (OPEN). In dieser Zeit werden neue Requests blockiert. Der Cache-Fallback hält die letzten bekannten Werte im Prometheus-Gauge. Nach 60s wechselt CB in HALF_OPEN und testet erneut.

**3. Was ist eine DLQ und warum brauchen wir sie?**  
→ Dead-Letter Queue: Datenpunkte die nach allen Retries nicht gespeichert werden konnten, landen dort. Kein Datenverlust. Können später manuell oder automatisch replayed werden.

**4. Wie stellst du sicher, dass kein Datenpunkt doppelt in der DB landet?**  
→ `ON CONFLICT DO NOTHING` auf dem Unique-Constraint `(time, elevator_id)`. Derselbe Datenpunkt kann beliebig oft gesendet werden, nur der erste Insert wird gespeichert.

**5. Wie kommen neue Aufzüge rein ohne Code zu ändern?**  
→ `poller_config.yaml`: Neuen Source-Block hinzufügen, Service neu starten, fertig.

### Google Cloud spezifisch:

**6. Warum Cloud Run statt VM (Compute Engine)?**  
→ Kein OS-Management, automatisches Scaling, zahlt nur für Laufzeit, integrierter Health-Check-Neustart, Secrets aus Secret Manager.

**7. Warum Cloud Run Jobs für Forecast und nicht dauerhafter Service?**  
→ Der Forecast läuft 10 Minuten täglich. Ein dauerhafter Service der 23h50m wartet ist Ressourcenverschwendung. Cloud Run Jobs starten on-demand.

**8. Wie wird die Datenbankverbindung in der Cloud abgesichert?**  
→ Cloud SQL Auth Proxy: kein öffentlicher DB-Port, verschlüsselter Unix-Socket, Authentifizierung via Service Account IAM. `DB_SSLMODE=require` erzwingt TLS.

**9. Wie werden API-Keys und Passwörter in der Cloud gespeichert?**  
→ Google Secret Manager. Nicht im Code, nicht in Docker-Images. Cloud Run erhält sie als Umgebungsvariablen zur Laufzeit.

---

*Erstellt mit Claude Code · Projektarbeit Datenbanken 2 · DHBW*

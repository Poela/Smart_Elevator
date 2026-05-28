# Elevator Monitoring – Campus Heilbronn

Echtzeit-Monitoring, Historienanalyse und prädiktive Steuerung von Aufzugsfahrten
am Bildungscampus Heilbronn. Datenquellen: CSV-Historien (L-Bau), Elevision REST-API
(Campus-Aufzüge) und DWD OpenData (Wetter Öhringen).

---

## Inhaltsverzeichnis

1. [Architekturübersicht](#1-architekturübersicht)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Projektstruktur](#3-projektstruktur)
4. [Installation](#4-installation)
5. [Datenbank-Schema anwenden](#5-datenbank-schema-anwenden)
6. [Erstimport (einmalig)](#6-erstimport-einmalig)
7. [Dauerbetrieb starten](#7-dauerbetrieb-starten)
8. [Grafana-Dashboards](#8-grafana-dashboards)
9. [Observability & Monitoring](#9-observability--monitoring)
10. [Konfigurationsreferenz](#10-konfigurationsreferenz)
11. [Nützliche Befehle](#11-nützliche-befehle)
12. [Fehlerbehebung](#12-fehlerbehebung)

---

## 1. Architekturübersicht

```
Datenquellen                Ingest-Schicht                Persistenz         Visualisierung
─────────────               ──────────────                ──────────         ──────────────

CSV-Historien   ──────────► csv_importer.py  (einmalig)
                                                              │
Elevision API   ──────────► api_poller.py    (60 s)          │
                ──────────► extended_poller  (1 min–1 h)  ───► TimescaleDB ──► Grafana
                                                              │    (Port      (Port 3000)
DWD OpenData    ──────────► dwd_history_importer (einmalig)  │     5432)
DWD WarnWetter  ──────────► dwd_poller.py    (60 min)        │
                                                              │
                            forecast_service.py (tägl. 02:00) ──► elevator_forecast
                            anomaly_alerter.py  (tägl. 07:00) ──► alert_log
```

| Komponente | Technologie | Port |
|---|---|---|
| Zeitreihendatenbank | TimescaleDB (PostgreSQL 16) | 5432 |
| Dashboard | Grafana 11.1 | 3000 |
| API-Poller Metrics | Prometheus-Endpunkt | 8080 |
| Extended-Poller Metrics | Prometheus-Endpunkt | 8081 |
| Anomalie-Alerter Metrics | Prometheus-Endpunkt | 8082 |

---

## 2. Voraussetzungen

| Software | Mindestversion | Version prüfen |
|---|---|---|
| **Docker Desktop** | 24.x | `docker --version` |
| **Python** | **3.10** | `python --version` |
| **Git** | beliebig | `git --version` |

> **Windows:** Docker Desktop muss gestartet sein (Taskleisten-Icon sichtbar).
> Das Projekt wurde unter Windows 11 mit PowerShell entwickelt.

---

## 3. Projektstruktur

```
elevator-monitoring/
│
├── docker-compose.yml              # TimescaleDB + Grafana Container
├── .env                            # Zugangsdaten (NICHT committen)
├── requirements.txt                # Python-Abhängigkeiten
├── poller_config.yaml              # Elevision Controller-Konfiguration
├── start_all.ps1                   # Tagesstart: alle Dienste auf einmal starten
│
├── schema.sql                      # Vollständiges DB-Schema (wird auto. angewendet)
├── migration_elevision.sql         # Erweiterung für bestehende Installationen
├── migration_v2.sql                # Schema-Erweiterungen v2 für bestehende DBs
│
├── History_Daten_Elevator/         # CSV-Rohdaten (einmalig importieren)
│   ├── Aufzug links L-Bau.csv
│   ├── Aufzug rechts L-Bau.csv
│   ├── Campus Bruecken HN West.csv
│   └── Feuerwehraufzug L-Bau.csv
│
├── csv_importer.py                 # Einmalig: CSV-Historien -> DB
├── dwd_history_importer.py         # Einmalig: DWD-Wetterdaten ab 1947 -> DB
│
├── api_poller.py                   # Dauerbetrieb: Stockwerk alle 60 s
├── elevision_extended_poller.py    # Dauerbetrieb: Fehler, Türen, Statistiken
├── dwd_poller.py                   # Dauerbetrieb: DWD Live-Wetter (stündlich)
├── forecast_service.py             # Dauerbetrieb: ML-Prognose (tägl. 02:00)
├── anomaly_alerter.py              # Dauerbetrieb: Anomalie-Alerts (tägl. 07:00)
│
└── grafana/
    ├── dashboards/                 # 6 Dashboard-JSON-Definitionen
    └── provisioning/               # Automatische Grafana-Konfiguration
        ├── alerting/
        ├── dashboards/
        └── datasources/
```

---

## 4. Installation

### 4.1 Repository klonen / Ordner öffnen

```powershell
cd C:\Users\phemb\Desktop\elevator-monitoring
```

### 4.2 Umgebungsvariablen prüfen

Die Datei `.env` enthält alle Zugangsdaten. Für den lokalen Betrieb müssen
die DB-Werte **nicht** geändert werden – sie passen zur `docker-compose.yml`.

```env
# Datenbankverbindung
DB_HOST=localhost
DB_PORT=5432
DB_NAME=elevator_db
DB_USER=postgres
DB_PASSWORD=Test123

# Elevision API (eigene Zugangsdaten eintragen)
ELEVISION_API_BASE=https://api.elevision.de/
ELEVISION_JWT_TOKEN=<JWT-Token hier eintragen>

# DWD-Poller
DWD_STATION_ID=10729
DWD_POLL_INTERVAL_SEC=3600

# Logging & Metriken
LOG_LEVEL=INFO
METRICS_PORT=8080
```

> Die `ELEVISION_JWT_TOKEN`-Variable muss für die Live-API-Anbindung gesetzt sein.
> Ohne Token laufen csv_importer und dwd_poller trotzdem vollständig.

### 4.3 Python-Umgebung einrichten

```powershell
# Virtuelle Umgebung erstellen (einmalig)
python -m venv venv

# Aktivieren (Windows PowerShell)
.\venv\Scripts\Activate.ps1

# Abhängigkeiten installieren
pip install -r requirements.txt
```

> Falls `Activate.ps1` blockiert wird:
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```

### 4.4 Docker-Stack starten

```powershell
docker compose up -d
```

Dieser Befehl startet zwei Container:

| Container | Image | Beschreibung |
|---|---|---|
| `elevator-monitoring-timescaledb-1` | `timescale/timescaledb:latest-pg16` | Datenbank |
| `elevator-monitoring-grafana-1` | `grafana/grafana:11.1.0` | Dashboard |

**Warten bis die Datenbank bereit ist** (ca. 30–60 Sekunden):

```powershell
docker compose ps
```

Erwartete Ausgabe wenn bereit:
```
NAME                                    STATUS
elevator-monitoring-timescaledb-1       Up (healthy)
elevator-monitoring-grafana-1           Up
```

> Wichtig: Erst wenn `timescaledb` den Status `healthy` hat, können Daten
> importiert werden. Das Schema aus `schema.sql` wird dabei automatisch
> beim ersten Start angelegt.

---

## 5. Datenbank-Schema anwenden

### Neuinstallation (Standard)

Bei einer Neuinstallation wird `schema.sql` automatisch durch Docker beim
ersten Start ausgeführt. **Kein manueller Schritt nötig.**

Das Schema legt an:
- Alle Tabellen (elevators, sensors, elevator_events, Wetter, API-Tabellen)
- TimescaleDB-Hypertables mit Partitionierung
- Continuous Aggregates (stündlich + täglich)
- Retention Policies
- Alle Indexes (Zeit, Sensor-ID, JSONB GIN, Geo)
- Views (v_current_floor, v_trip_anomalies, v_latest_forecast, etc.)

### Bestehende Installation aktualisieren

Nur nötig, wenn die Datenbank bereits existiert und auf eine neue Version
aktualisiert werden soll:

```powershell
# Schema-Erweiterungen v2 (Sensor-Registry, quality_flag, JSONB-Felder)
Get-Content migration_v2.sql | docker exec -i elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db

# Elevision API-Tabellen (elevator_errors, elevator_door_stats, etc.)
Get-Content migration_elevision.sql | docker exec -i elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db
```

### Schema manuell prüfen

```powershell
# Alle Tabellen anzeigen
docker exec -it elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db -c "\dt"

# Hypertables anzeigen
docker exec -it elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"
```

---

## 6. Erstimport (einmalig)

Diese Schritte werden **einmalig** beim ersten Aufsetzen ausgeführt.
Danach übernehmen die Poller die laufende Aktualisierung.

### 6.1 Aufzugs-CSV-Historien importieren

Liest alle CSV-Dateien aus `History_Daten_Elevator/` und schreibt sie in
`elevator_events`. Der Import ist idempotent – mehrfaches Ausführen
schreibt keine Duplikate.

```powershell
# venv muss aktiviert sein
python csv_importer.py
```

Erwartete Ausgabe:
```
=== Elevator CSV-Importer gestartet ===
Verarbeite: Aufzug links L-Bau.csv
  934 Datensaetze importiert (Aufzug-ID: 1)
Verarbeite: Aufzug rechts L-Bau.csv
  1028 Datensaetze importiert (Aufzug-ID: 2)
...
=== Import abgeschlossen: 7227 Datensaetze gesamt ===
```

### 6.2 DWD-Wetterdaten importieren

Lädt historische Wetterdaten der Station Öhringen (nächste DWD-Station
zu Heilbronn, ~15 km) ab 1947 und aktuelle Vorhersagen.

```powershell
# Komplette Historie + aktuelle Daten (empfohlen beim ersten Start)
python dwd_history_importer.py --range both
```

| Option | Beschreibung |
|---|---|
| `--range recent` | Letzte ~18 Monate (schnell, ~550 Datensätze) |
| `--range historical` | Messreihe ab 01.01.1947 (~28.000 Datensätze) |
| `--range both` | Beides kombiniert (empfohlen) |
| `--dry-run` | Vorschau ohne DB-Schreibzugriff |

Erwartete Ausgabe:
```
=== DWD History Import: recent ===
  550 Records in weather_observations gespeichert.
=== DWD History Import: historical ===
  28490 Records in weather_observations gespeichert.
```

---

## 7. Dauerbetrieb starten

### Option A – Alle Dienste auf einmal (empfohlen)

Das PowerShell-Skript `start_all.ps1` prüft Docker, importiert aktuelle
DWD-Daten und öffnet jeden Dienst in einem eigenen Terminalfenster:

```powershell
.\start_all.ps1
```

Das Skript startet automatisch:
- DWD Wetter-Poller (alle 60 min)
- Elevision API-Poller (alle 60 s)
- Elevision Extended Poller (1 min / 5 min / 10 min / 1 h)
- ML-Forecast Service (täglich 02:00 Uhr)
- Anomalie-Alerter (täglich 07:00 Uhr)

> Voraussetzung: venv muss unter `.\venv\` existieren und `requirements.txt`
> installiert sein (Schritt 4.3).

---

### Option B – Dienste einzeln starten

Jeden Befehl in einem **separaten** PowerShell-Fenster ausführen.
Immer zuerst die venv aktivieren:

```powershell
.\venv\Scripts\Activate.ps1
```

#### DWD Wetter-Poller

Aktualisiert Wetterdaten stündlich (Tageswerte + 10-Tages-Forecast).

```powershell
python dwd_poller.py --loop
```

#### Elevision API-Poller (Hauptpoller)

Holt alle 60 Sekunden das aktuelle Stockwerk jedes konfigurierten Controllers.
Enthält Circuit Breaker, Rate Limiter, Dead-Letter-Queue und Prometheus-Metriken.

```powershell
python api_poller.py
```

#### Elevision Extended Poller

Holt zusätzliche Daten von der Elevision API:

| Endpunkt | Tabelle | Intervall |
|---|---|---|
| `/overview` | `elevator_availability` | 60 s |
| `/events/{id}/` | `elevator_errors` | 5 min |
| `/conditions/doors` | `elevator_door_stats` | 10 min |
| `/statistics/count` | `elevator_count_stats` | 1 h |
| `/statistics/time` | `elevator_time_stats` | 1 h |

```powershell
python elevision_extended_poller.py
```

#### ML-Forecast Service

Trainiert täglich um 02:00 Uhr ein LightGBM-Modell pro Aufzug und schreibt
14-Tage-Prognosen mit Konfidenzintervallen in `elevator_forecast`.

```powershell
# Einmaliger Lauf (sofort trainieren und prognostizieren)
python forecast_service.py

# Dauerbetrieb (täglich 02:00 Uhr)
python forecast_service.py --loop

# Nur Metriken ausgeben (MAE, RMSE, MAPE, Coverage)
python forecast_service.py --evaluate
```

#### Anomalie-Alerter

Prüft täglich um 07:00 Uhr die Fahrtenmuster aller Aufzüge auf statistische
Ausreißer (Z-Score-Methode) und schreibt Alerts ins Log und in `alert_log`.

```powershell
# Einmaliger Lauf (gestern prüfen)
python anomaly_alerter.py

# Dauerbetrieb (täglich 07:00 Uhr)
python anomaly_alerter.py --loop

# Letzte 7 Tage prüfen
python anomaly_alerter.py --days 7
```

Alert-Schwellen (konfigurierbar per `.env`):
- `|Z-Score| > 2.0` → **KRITISCH** (Ausreißer)
- `|Z-Score| > 1.5` → **WARNUNG** (Auffällig)

---

## 8. Grafana-Dashboards

**URL:** [http://localhost:3000](http://localhost:3000)
**Login:** `admin` / `admin`

> Beim ersten Login erscheint ein Passwort-Dialog. Dieser kann mit
> „Skip" übersprungen werden.

Das Dashboard wird beim ersten Start automatisch eingerichtet –
keine manuelle Konfiguration nötig.

| Dashboard | Inhalt |
|---|---|
| **Übersicht** | Live-Status, Stockwerkverlauf, Fahrtenauslastung aller Aufzüge |
| **Analyse & Prognose** | Stunden-/Wochenmuster, 14-Tage-ML-Prognose, Anomalie-Erkennung, Wetter-Korrelation |
| **Prädiktive Steuerung** | API-Verbindungsstatus, Live-Ereignisse, Empfehlungssystem |
| **Türen** | Öffnungs-/Schließzeiten, Reversierungen, Türzyklen |
| **Fehler** | Fehlerrate, Fehlertypen, Verfügbarkeit |
| **Motorstatistik** | Motorstarts, Fahrtzeit, Leerlauf, Distanz, Car-/Landing-Calls |

---

## 9. Observability & Monitoring

Jeder Poller stellt Prometheus-Metriken und Health-Endpoints bereit:

| Dienst | Port | Endpunkte |
|---|---|---|
| `api_poller.py` | **8080** | `/health`, `/ready`, `/metrics` |
| `elevision_extended_poller.py` | **8081** | `/health`, `/ready`, `/metrics` |
| `anomaly_alerter.py` | **8082** | `/health`, `/metrics` |

### Health-Check

```powershell
# Datenbank erreichbar?
Invoke-WebRequest http://localhost:8080/health | Select-Object -Expand Content

# Scheduler bereit?
Invoke-WebRequest http://localhost:8080/ready | Select-Object -Expand Content
```

Erwartete Antworten:
```json
{"status":"ok","db":"connected"}
{"status":"ready"}
```

### Prometheus-Metriken (Auswahl)

```powershell
Invoke-WebRequest http://localhost:8080/metrics | Select-Object -Expand Content
```

| Metrik | Beschreibung |
|---|---|
| `elevator_poll_total` | Gesamtanzahl API-Abfragen |
| `elevator_poll_errors_total` | Fehler nach Quelle und Typ |
| `elevator_poll_duration_seconds` | Abfragedauer (Histogramm) |
| `elevator_circuit_breaker_open` | CB-Status: 1=OPEN, 0=geschlossen |
| `elevator_dlq_size_total` | Offene Dead-Letter-Queue-Einträge |
| `elevator_last_successful_poll_unixtime` | Zeitstempel letzter erfolgreicher Poll |
| `elevator_alert_total` | Erkannte Anomalien nach Schweregrad |

### Circuit-Breaker-Status

Der Circuit Breaker öffnet nach 5 aufeinanderfolgenden Fehlern und pausiert
alle Requests für 60 Sekunden. Danach wird ein Probe-Request gesendet.

Schwellenwerte in `.env` konfigurierbar:
```env
CB_FAILURE_THRESHOLD=5        # Fehler bis zum Öffnen
CB_RECOVERY_TIMEOUT_SEC=60    # Wartezeit bis Probe-Request
```

---

## 10. Konfigurationsreferenz

### `.env` – Vollständige Optionen

```env
# ── Datenbank ────────────────────────────────────────────────
DB_HOST=localhost
DB_PORT=5432
DB_NAME=elevator_db
DB_USER=postgres
DB_PASSWORD=Test123

# ── Elevision API ─────────────────────────────────────────────
ELEVISION_API_BASE=https://api.elevision.de/
ELEVISION_JWT_TOKEN=<JWT-Token>

# ── DWD-Poller ────────────────────────────────────────────────
DWD_STATION_ID=10729            # WMO-ID Öhringen (nicht ändern)
DWD_POLL_INTERVAL_SEC=3600      # Abrufintervall in Sekunden

# ── Logging ───────────────────────────────────────────────────
LOG_LEVEL=INFO                  # DEBUG | INFO | WARNING | ERROR

# ── Poller-Einstellungen ──────────────────────────────────────
METRICS_PORT=8080               # api_poller.py Metrics-Port
EXT_METRICS_PORT=8081           # extended_poller Metrics-Port
ALERT_METRICS_PORT=8082         # anomaly_alerter Metrics-Port
POLLER_CONFIG=poller_config.yaml

# ── Circuit Breaker ───────────────────────────────────────────
CB_FAILURE_THRESHOLD=5          # Fehler bis CB öffnet
CB_RECOVERY_TIMEOUT_SEC=60      # Pause bis Probe-Request

# ── Anomalie-Alerter ──────────────────────────────────────────
ALERT_Z_CRITICAL=2.0            # Z-Score für KRITISCH-Alert
ALERT_Z_WARNING=1.5             # Z-Score für WARNUNG-Alert

# ── ML-Forecast ───────────────────────────────────────────────
FORECAST_HORIZON_DAYS=14        # Prognosehorizont in Tagen
FORECAST_HISTORY_DAYS=365       # Trainingsdaten in Tagen
FORECAST_HOLDOUT_DAYS=7         # Holdout-Tage für Evaluation
FORECAST_LOOP_HOUR=2            # Uhrzeit tägliches Training
```

### `poller_config.yaml` – Controller konfigurieren

Neue Elevision-Controller werden ausschließlich hier eingetragen –
**kein Code-Change nötig** (config-driven ingest):

```yaml
sources:

  - name: "Mein Aufzug"
    url: "${ELEVISION_API_BASE}/publicapi/controllers/123456"
    api_key: "${ELEVISION_JWT_TOKEN}"
    poll_interval_sec: 60       # Abrufintervall
    timeout_sec: 10             # Request-Timeout
    rate_limit_rps: 1.0         # Max. Requests/Sekunde (Fairness)
    field_mapping:
      elevator_name: "name"                  # API-Feldname fuer den Namen
      floor: "liftStatus.car.floor"          # Dot-Notation fuer verschachtelte Felder
      # elevator_name_override: "DB-Name"    # Falls API-Name != DB-Name
```

---

## 11. Nützliche Befehle

### Docker

```powershell
# Stack starten
docker compose up -d

# Stack stoppen (Daten bleiben erhalten)
docker compose stop

# Stack komplett entfernen inkl. aller Daten
docker compose down -v

# Logs live verfolgen
docker compose logs -f timescaledb
docker compose logs -f grafana

# Datenbank-Shell öffnen
docker exec -it elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db
```

### Datenbank-Abfragen

```sql
-- Aktuelles Stockwerk aller Aufzüge
SELECT elevator_name, current_floor, last_seen FROM v_current_floor;

-- Ereignisse pro Aufzug und Quelle
SELECT e.name, ev.source, COUNT(*)
FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id
GROUP BY e.name, ev.source ORDER BY e.name;

-- Wetterdaten prüfen
SELECT MIN(time)::date AS von, MAX(time)::date AS bis, COUNT(*)
FROM weather_observations;

-- Letzte ML-Prognose
SELECT elevator_name, time::date, yhat, yhat_lower, yhat_upper
FROM v_latest_forecast ORDER BY time LIMIT 10;

-- Offene Anomalie-Alerts
SELECT elevator, check_day, severity, z_score, message
FROM alert_log ORDER BY triggered_at DESC LIMIT 20;

-- Dead-Letter-Queue (fehlgeschlagene API-Records)
SELECT COUNT(*) AS offen
FROM elevator_events_dlq WHERE resolved_at IS NULL;

-- Stundenmittel (Continuous Aggregate)
SELECT bucket, elevator_id, avg_floor, trip_count
FROM ev_hourly ORDER BY bucket DESC LIMIT 20;
```

### Python-Umgebung

```powershell
# venv aktivieren (Windows)
.\venv\Scripts\Activate.ps1

# Abhängigkeiten neu installieren
pip install -r requirements.txt

# Forecast manuell auslösen
python forecast_service.py --evaluate

# Anomalien der letzten 30 Tage prüfen
python anomaly_alerter.py --days 30

# DWD-Import testen (kein DB-Schreibzugriff)
python dwd_history_importer.py --dry-run
```

---

## 12. Fehlerbehebung

| Fehler | Ursache | Lösung |
|---|---|---|
| `psycopg2.OperationalError: could not connect` | Docker nicht gestartet oder DB nicht bereit | `docker compose up -d`, dann 60 s warten |
| `timescaledb` zeigt Status `starting` | DB startet noch | `docker compose ps` wiederholen bis `healthy` |
| `ModuleNotFoundError` | venv nicht aktiviert | `.\venv\Scripts\Activate.ps1` |
| `FileNotFoundError: poller_config.yaml` | Falsches Arbeitsverzeichnis | `cd elevator-monitoring` |
| Grafana zeigt „No data" | CSV noch nicht importiert | `python csv_importer.py` |
| Grafana zeigt „datasource error" | DB-Container nicht bereit | `docker compose ps` prüfen |
| API-Poller: `HTTP 401` | JWT-Token abgelaufen | Neuen Token in `.env` eintragen |
| API-Poller: Circuit Breaker OPEN | 5 Fehler in Folge | Automatische Erholung nach 60 s |
| `Activate.ps1 cannot be loaded` | PowerShell Execution Policy | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| Schema fehlt (Tabelle existiert nicht) | Erster Start nicht abgeschlossen | `docker compose down -v && docker compose up -d` |

---

## Datenfluss

```
Einmalig (Setup):
  History_Daten_Elevator/*.csv  ──► csv_importer.py         ──► elevator_events
  DWD OpenData (Station 03761)  ──► dwd_history_importer.py ──► weather_observations

Dauerbetrieb:
  Elevision /controllers/{id}   ──► api_poller.py   (60 s)   ──► elevator_events
  Elevision /overview           ──► extended_poller (60 s)   ──► elevator_availability
  Elevision /events/{id}/       ──► extended_poller (5 min)  ──► elevator_errors
  Elevision /conditions/doors   ──► extended_poller (10 min) ──► elevator_door_stats
  Elevision /statistics/count   ──► extended_poller (1 h)    ──► elevator_count_stats
  Elevision /statistics/time    ──► extended_poller (1 h)    ──► elevator_time_stats
  DWD WarnWetter API            ──► dwd_poller.py   (60 min) ──► weather_observations
                                                                  weather_hourly

Automatisch (TimescaleDB Continuous Aggregates):
  elevator_events ──► ev_hourly (1-Stunden-Mittel, refresh stündlich)
  elevator_events ──► ev_daily  (Tagesmittel, refresh täglich)

Täglich (Hintergrunddienste):
  elevator_events + weather  ──► forecast_service.py (02:00) ──► elevator_forecast
  elevator_events            ──► anomaly_alerter.py  (07:00) ──► alert_log

Retention (automatisch durch TimescaleDB):
  elevator_events        ──► 1 Jahr
  elevator_errors        ──► 1 Jahr
  elevator_door_stats    ──► 1 Jahr
  elevator_count_stats   ──► 2 Jahre
  elevator_time_stats    ──► 2 Jahre
  elevator_availability  ──► 90 Tage
  weather_observations   ──► 3 Jahre
  weather_hourly         ──► 90 Tage
```

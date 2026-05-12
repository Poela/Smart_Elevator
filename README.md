# Elevator Monitoring – Heilbronn

Echtzeit-Monitoring und Historienanalyse von Aufzugsfahrten am Campus Heilbronn.  
Datenquellen: CSV-Historien, REST-API (Aufzüge), DWD OpenData + WarnWetter-API (Wetter).

---

## Inhaltsverzeichnis

1. [Projektübersicht](#1-projektübersicht)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Projektstruktur](#3-projektstruktur)
4. [Schnellstart](#4-schnellstart)
5. [Schritt-für-Schritt-Installation](#5-schritt-für-schritt-installation)
6. [Daten importieren](#6-daten-importieren)
7. [Poller im Dauerbetrieb](#7-poller-im-dauerbetrieb)
8. [Grafana-Dashboard](#8-grafana-dashboard)
9. [Konfigurationsreferenz](#9-konfigurationsreferenz)
10. [Nützliche Befehle](#10-nützliche-befehle)

---

## 1. Projektübersicht

```
CSV-Historien ──┐
Aufzugs-API ────┼──► TimescaleDB (PostgreSQL) ──► Grafana-Dashboard
DWD OpenData ───┤         (Docker)
DWD WarnWetter ─┘
```

| Komponente | Technologie | Port |
|---|---|---|
| Zeitreihendatenbank | TimescaleDB (PostgreSQL 16) | 5432 |
| Dashboard | Grafana 11 | 3000 |
| Wetter-Historien | DWD OpenData (Öhringen, ab 1947) | – |
| Wetter-Live | DWD WarnWetter API (stündlich) | – |
| Aufzugs-Live | REST-API Poller (konfigurierbar) | 8080 (Metrics) |

---

## 2. Voraussetzungen

| Software | Mindestversion | Prüfen |
|---|---|---|
| **Docker Desktop** | 24.x | `docker --version` |
| **Python** | **3.10** | `python --version` |
| **Git** | beliebig | `git --version` |

> **Windows-Hinweis:** Docker Desktop muss laufen (Taskleisten-Icon sichtbar).

---

## 3. Projektstruktur

```
elevator-monitoring/
│
├── docker-compose.yml          # TimescaleDB + Grafana
├── .env                        # Datenbankzugangsdaten (nicht committen!)
├── requirements.txt            # Python-Abhängigkeiten
├── poller_config.yaml          # Aufzugs-API Konfiguration
│
├── schema.sql                  # Datenbankschema (wird automatisch angewendet)
├── migration_v2.sql            # Schema-Erweiterungen (für bestehende Instanzen)
├── create_views.sql            # Grafana-Views (optional, bereits in schema.sql)
│
├── History_Daten_Elevator/     # CSV-Rohdaten (4 Aufzüge)
│   ├── Aufzug links L-Bau.csv
│   ├── Aufzug rechts L-Bau.csv
│   ├── Campus Brücken HN West.csv
│   └── Feuerwehraufzug L-Bau.csv
│
├── csv_importer.py             # Einmalig: CSV-Historien → DB
├── dwd_history_importer.py     # Einmalig: DWD-Wetterdaten ab 1947 → DB
├── dwd_poller.py               # Dauerbetrieb: DWD Live-Wetter (stündlich)
├── api_poller.py               # Dauerbetrieb: Aufzugs-API (konfigurierbar)
│
└── grafana/
    ├── dashboards/             # JSON-Dashboard-Definitionen
    └── provisioning/           # Automatische Grafana-Konfiguration
```

---

## 4. Schnellstart

> Für eine frische Installation in 5 Schritten.

```bash
# 1. Docker-Stack starten
docker compose up -d

# 2. Python-Umgebung einrichten
python -m venv venv
venv\Scripts\activate          # Windows
pip install -r requirements.txt

# 3. Aufzugs-CSV importieren
python csv_importer.py

# 4. Wetterdaten laden
python dwd_history_importer.py --range both

# 5. Grafana öffnen
# → http://localhost:3000  (admin / admin)
```

---

## 5. Schritt-für-Schritt-Installation

### 5.1 Repository einrichten

```bash
# Projekt-Ordner öffnen (oder klonen)
cd elevator-monitoring
```

### 5.2 Umgebungsvariablen konfigurieren

Die Datei `.env` enthält die Datenbankzugangsdaten:

```env
DB_HOST=localhost
DB_PORT=5432
DB_NAME=elevator_db
DB_USER=postgres
DB_PASSWORD=Test123
```

> Die Standardwerte passen zur `docker-compose.yml` und müssen für den lokalen Betrieb nicht geändert werden.

### 5.3 Docker-Stack starten

```bash
docker compose up -d
```

Dies startet zwei Container:

| Container | Image | Beschreibung |
|---|---|---|
| `elevator-monitoring-timescaledb-1` | timescale/timescaledb:latest-pg16 | Datenbank (Schema wird automatisch angelegt) |
| `elevator-monitoring-grafana-1` | grafana/grafana:11.1.0 | Dashboard |

**Status prüfen:**
```bash
docker compose ps
```

Warten bis `timescaledb` den Status `healthy` hat (ca. 30 Sekunden):
```
NAME                                    STATUS
elevator-monitoring-timescaledb-1       Up (healthy)
elevator-monitoring-grafana-1           Up
```

### 5.4 Python-Umgebung einrichten

```bash
# Virtuelle Umgebung erstellen
python -m venv venv

# Aktivieren (Windows)
venv\Scripts\activate

# Aktivieren (Linux/Mac)
source venv/bin/activate

# Abhängigkeiten installieren
pip install -r requirements.txt
```

### 5.5 Schema auf bestehende Datenbank anwenden (nur bei Update)

> Nur nötig, wenn die Datenbank bereits existiert und aktualisiert werden soll.  
> Bei Neuinstallation übernimmt `schema.sql` alles automatisch.

```bash
docker exec -i elevator-monitoring-timescaledb-1 \
  psql -U postgres -d elevator_db < migration_v2.sql
```

---

## 6. Daten importieren

### 6.1 Aufzugs-CSV-Historien

Liest die vier CSV-Dateien aus `History_Daten_Elevator/` und schreibt sie in die Datenbank.

```bash
python csv_importer.py
```

**Erwartete Ausgabe:**
```
=== Elevator CSV-Importer gestartet ===
Verarbeite: Aufzug links L-Bau.csv
  ✓ 934 Datensätze importiert (Aufzug-ID: 1)
...
=== Import abgeschlossen: 7227 Datensätze gesamt ===
```

> Der Import ist idempotent – mehrfaches Ausführen schreibt keine Duplikate.

### 6.2 DWD-Wetterdaten (Öhringen / Heilbronn)

#### Komplette Historien laden (empfohlen beim ersten Start)

```bash
python dwd_history_importer.py --range both
```

| Option | Beschreibung | Zeitraum |
|---|---|---|
| `--range recent` | Letzte ~18 Monate | Standard |
| `--range historical` | Komplette Messreihe | ab 01.01.1947 |
| `--range both` | Beides zusammen | ab 01.01.1947 |
| `--dry-run` | Vorschau ohne DB-Schreibzugriff | – |

**Erwartete Ausgabe (`--range both`):**
```
=== DWD History Import: recent ===
  ✓ 550 Records in weather_observations gespeichert.
=== DWD History Import: historical ===
  ✓ 28490 Records in weather_observations gespeichert.
```

> Quelle: DWD OpenData Station Öhringen (03761), ~15 km von Heilbronn.  
> Daten werden unter WMO-Station-ID `10729` gespeichert.

---

## 7. Poller im Dauerbetrieb

Die Poller laufen dauerhaft und aktualisieren die Daten regelmäßig.  
Am besten in separaten Terminal-Fenstern oder als Hintergrunddienst starten.

### 7.1 DWD-Wetter-Poller (Live-Wetter + 10-Tages-Forecast)

```bash
# Einmaliger Test
python dwd_poller.py

# Dauerbetrieb (alle 60 Minuten)
python dwd_poller.py --loop
```

**Was wird gespeichert:**
- `weather_observations`: Tageswerte (Temp, Regen, Wind) – 10 Tage Forecast
- `weather_hourly`: Stündliche Vorhersage – 10 Tage

### 7.2 Aufzugs-API-Poller (Echtzeit-Fahrtendaten)

> Voraussetzung: Zugangsdaten für die Aufzugs-API in `.env` und `poller_config.yaml` eintragen.

**`poller_config.yaml` anpassen:**
```yaml
sources:
  - name: "Aufzüge L-Bau"
    url: "${ELEVATOR_API_URL}"       # URL in .env setzen
    api_key: "${ELEVATOR_API_KEY}"   # API-Key in .env setzen
    poll_interval_sec: 60
    field_mapping:
      elevator_name: "name"
      floor: "currentFloor"
```

**`.env` ergänzen:**
```env
ELEVATOR_API_URL=https://ihre-api.beispiel.de/elevators
ELEVATOR_API_KEY=ihr-api-key
```

**Starten:**
```bash
python api_poller.py
```

**Monitoring-Endpunkte (Port 8080):**

| Endpunkt | Beschreibung |
|---|---|
| `http://localhost:8080/health` | Datenbankverbindung (200 = OK) |
| `http://localhost:8080/ready` | Scheduler-Status (200 = bereit) |
| `http://localhost:8080/metrics` | Prometheus-Metriken |

---

## 8. Grafana-Dashboard

**URL:** [http://localhost:3000](http://localhost:3000)  
**Login:** `admin` / `admin`

Das Dashboard wird beim ersten Start automatisch bereitgestellt.

| Dashboard | Inhalt |
|---|---|
| **Elevator Monitoring** | Live-Status, Etagenverlauf, Fahrtenauslastung |
| **Analyse** | Stunden-/Wochenmuster, Predictive Control |
| **Wetter-Korrelation** | Fahrten vs. Temperatur, Regen, Sonnenstunden |

> Beim ersten Login fordert Grafana eine Passwortänderung.  
> Das Passwort kann übersprungen werden (Button „Skip").

---

## 9. Konfigurationsreferenz

### `.env` – Vollständige Optionen

```env
# Datenbank (TimescaleDB)
DB_HOST=localhost
DB_PORT=5432
DB_NAME=elevator_db
DB_USER=postgres
DB_PASSWORD=Test123

# DWD-Poller
DWD_STATION_ID=10729            # WMO-ID Öhringen (Standard, nicht ändern)
DWD_POLL_INTERVAL_SEC=3600      # Abrufintervall in Sekunden (Standard: 1h)

# Aufzugs-API (nur für api_poller.py)
ELEVATOR_API_URL=
ELEVATOR_API_KEY=

# Logging
LOG_LEVEL=INFO                  # DEBUG | INFO | WARNING | ERROR

# API-Poller Optionen
METRICS_PORT=8080               # Port für Health/Metrics-Endpunkte
CB_FAILURE_THRESHOLD=5          # Circuit-Breaker öffnet nach N Fehlern
CB_RECOVERY_TIMEOUT_SEC=60      # Sekunden bis zum Erholungsversuch
```

### `poller_config.yaml` – Mehrere Quellen

```yaml
sources:
  - name: "Aufzüge L-Bau"
    url: "${ELEVATOR_API_URL}"
    api_key: "${ELEVATOR_API_KEY}"
    poll_interval_sec: 60          # Abrufintervall
    timeout_sec: 10                # Request-Timeout
    rate_limit_rps: 1.0            # Max. Requests pro Sekunde
    field_mapping:
      elevator_name: "name"        # API-Feldname → interner Name
      floor: "currentFloor"        # API-Feldname → Stockwerk

  # Weitere Quellen analog ergänzen
  # - name: "Campus Aufzüge"
  #   url: "${CAMPUS_API_URL}"
  #   poll_interval_sec: 120
```

---

## 10. Nützliche Befehle

### Docker

```bash
# Stack starten
docker compose up -d

# Stack stoppen (Daten bleiben erhalten)
docker compose stop

# Stack komplett entfernen inkl. Daten
docker compose down -v

# Logs anzeigen
docker compose logs -f timescaledb
docker compose logs -f grafana

# Datenbank-Shell öffnen
docker exec -it elevator-monitoring-timescaledb-1 psql -U postgres -d elevator_db
```

### Datenbank-Abfragen

```sql
-- Aktuelle Stockwerke aller Aufzüge
SELECT elevator_name, current_floor, last_seen FROM v_current_floor;

-- Anzahl Events pro Aufzug
SELECT e.name, COUNT(*) FROM elevator_events ev
JOIN elevators e ON e.id = ev.elevator_id GROUP BY e.name;

-- Wetterdaten prüfen
SELECT source, COUNT(*), MIN(time)::date, MAX(time)::date
FROM weather_observations GROUP BY source;

-- Stundenmittel (Continuous Aggregate)
SELECT bucket, elevator_id, avg_floor, trip_count FROM ev_hourly
ORDER BY bucket DESC LIMIT 20;

-- Nicht aufgelöste Dead-Letter-Queue-Einträge
SELECT COUNT(*) FROM elevator_events_dlq WHERE resolved_at IS NULL;
```

### Python-Umgebung

```bash
# Umgebung aktivieren (Windows)
venv\Scripts\activate

# Umgebung aktivieren (Linux/Mac)
source venv/bin/activate

# Abhängigkeiten aktualisieren
pip install -r requirements.txt --upgrade

# Dry-Run: Wetterdaten ohne DB-Schreibzugriff testen
python dwd_history_importer.py --dry-run
```

### Typische Fehler

| Fehler | Ursache | Lösung |
|---|---|---|
| `psycopg2.OperationalError` | Docker-Container nicht gestartet | `docker compose up -d` |
| `ValueError: Aufzug ... nicht gefunden` | Schema nicht angewendet | `migration_v2.sql` ausführen |
| `ModuleNotFoundError` | venv nicht aktiviert | `venv\Scripts\activate` |
| Grafana zeigt keine Daten | CSV noch nicht importiert | `python csv_importer.py` |
| DWD liefert keine Daten | API temporär nicht erreichbar | Retry – DWD-Poller hat Backoff |

---

## Datenfluss

```
Einmalig (Setup):
  History_Daten_Elevator/*.csv  ──► csv_importer.py          ──► elevator_events
  DWD OpenData (Öhringen)       ──► dwd_history_importer.py  ──► weather_observations

Dauerbetrieb:
  Aufzugs-REST-API  ──► api_poller.py   (alle 60 s)  ──► elevator_events
  DWD WarnWetter    ──► dwd_poller.py   (alle 60 min) ──► weather_observations
                                                           weather_hourly

Automatisch (TimescaleDB):
  elevator_events ──► ev_hourly  (Continuous Aggregate, 1h-Mittel)
  elevator_events ──► ev_daily   (Continuous Aggregate, 1d-Mittel)
  Retention: elevator_events → 1 Jahr | weather_observations → 3 Jahre
```

# Google Cloud Deployment – Smart Elevator Monitoring

Vollständige Schritt-für-Schritt-Anleitung.  
Geschätzte Gesamtdauer: **20–30 Minuten** (davon ~10 Min. automatisch).  
Monatliche Kosten: **~$15–20** aus dem $300 Free-Trial-Guthaben (~15–20 Monate Laufzeit).

---

## Warum Google Cloud statt Azure?

Azure for Students hat eine Subscription-Policy, die Container Registry, PostgreSQL,
Storage Accounts und Log Analytics in fast allen Regionen blockiert.
Google Cloud hat diese Einschränkungen nicht — Cloud Run und Cloud SQL sind
für alle GCP-Accounts ohne regionale Policy-Sperren verfügbar.

---

## Inhaltsverzeichnis

1. [GCP-Projekt anlegen & Billing aktivieren](#1-gcp-projekt-anlegen--billing-aktivieren)
2. [gcloud CLI einrichten](#2-gcloud-cli-einrichten)
3. [Konfiguration anpassen](#3-konfiguration-anpassen)
4. [Deployment starten](#4-deployment-starten)
5. [Erstimport historischer Daten](#5-erstimport-historischer-daten)
6. [Grafana aufrufen](#6-grafana-aufrufen)
7. [Betrieb überwachen](#7-betrieb-überwachen)
8. [Kosten im Blick behalten](#8-kosten-im-blick-behalten)
9. [Häufige Fehler](#9-häufige-fehler)
10. [Alles löschen](#10-alles-löschen)

---

## 1. GCP-Projekt anlegen & Billing aktivieren

### Projekt erstellen

1. Öffne: https://console.cloud.google.com
2. Klicke oben auf das Projekt-Dropdown → **Neues Projekt**
3. Projektname: `elevator-monitoring` (oder beliebig)
4. Die **Projekt-ID** notieren — z.B. `elevator-monitoring-abc123`
   (wird automatisch generiert, du kannst sie anpassen)

### Free Trial / Billing aktivieren

**Option A – Free Trial ($300 Guthaben, Kreditkarte nötig):**
1. Im GCP Console-Banner: **"Free Trial aktivieren"** klicken
2. Land und Kreditkarte eingeben
3. Kreditkarte wird **nicht belastet** — nur zur Verifizierung
4. Du erhältst $300 Guthaben für 90 Tage

**Option B – GitHub Student Developer Pack (kein Kreditkarte nötig):**
1. Öffne: https://education.github.com/pack
2. Verifiziere deinen Studenten-Status
3. Aktiviere den Google Cloud-Vorteil → $300 Guthaben ohne Kreditkarte

### Billing mit Projekt verknüpfen

1. Öffne: https://console.cloud.google.com/billing/projects
2. Wähle dein Projekt → **Billing-Konto verknüpfen**
3. Wähle das Free-Trial-Konto aus

> **Wichtig:** Cloud Run und Cloud SQL funktionieren **nur** mit aktiviertem Billing,
> auch wenn du nur Free-Trial-Guthaben nutzt.

---

## 2. gcloud CLI einrichten

### Installation prüfen

```powershell
gcloud --version
```

Ausgabe sollte `Google Cloud SDK 4xx.x.x` zeigen. Falls nicht installiert:
https://cloud.google.com/sdk/docs/install → Windows Installer herunterladen.

### CLI initialisieren (einmalig)

```powershell
gcloud init
```

Das öffnet einen Browser. Mit deinem Google-Konto einloggen.
Dann das richtige Projekt auswählen, wenn gefragt.

### Anmeldung prüfen

```powershell
gcloud auth list
gcloud config get-value project
```

Beides sollte deinen Account und deine Projekt-ID zeigen.

---

## 3. Konfiguration anpassen

Öffne [gcp-deploy.ps1](gcp-deploy.ps1) und trage oben deine Werte ein:

```powershell
$PROJECT_ID     = "elevator-monitoring-abc123"  # deine Projekt-ID
$REGION         = "us-central1"                 # kann so bleiben
$DOCKERHUB_USER = "hiprabbit"                   # dein Docker Hub Name
```

Das Passwort und den JWT-Token kannst du ebenfalls dort eintragen oder
das Script fragt interaktiv danach.

---

## 4. Deployment starten

```powershell
.\gcp-deploy.ps1
```

### Was das Script im Einzelnen tut

| Schritt | Was passiert | Dauer |
|---------|-------------|-------|
| APIs aktivieren | Cloud Run, SQL, Scheduler einschalten | ~1 Min. |
| Cloud SQL erstellen | PostgreSQL 16, db-f1-micro, 10 GB SSD | ~5 Min. |
| Schema einspielen | `schema-gcp.sql` → Cloud SQL | ~30 Sek. |
| Grafana deployen | Cloud Run Service, öffentlich erreichbar | ~2 Min. |
| API-Poller deployen | Cloud Run, dauerhaft, alle 60s | ~1 Min. |
| Extended Poller | Cloud Run, dauerhaft | ~1 Min. |
| DWD-Poller | Cloud Run, dauerhaft, stündlich | ~1 Min. |
| Forecast-Job | Cloud Run Job + Cloud Scheduler 02:00 UTC | ~1 Min. |
| Alerter-Job | Cloud Run Job + Cloud Scheduler 07:00 UTC | ~1 Min. |

Am Ende gibt das Script die **Grafana-URL** aus.

### Typische Ausgabe

```
>>> GCP Authentifizierung
    OK  Eingeloggt als: deinname@gmail.com
    OK  Projekt gesetzt: elevator-monitoring-abc123

>>> Cloud SQL Instanz: elevator-db
    ... Erstelle Cloud SQL Instanz (dauert 3-5 Minuten)...
    OK  Cloud SQL Instanz erstellt
    OK  Cloud SQL IP: 34.xxx.xxx.xxx

>>> Datenbank und Schema einrichten
    OK  Schema eingespielt

>>> Grafana auf Cloud Run deployen
    OK  Grafana: https://grafana-abc123-uc.a.run.app

>>> API-Poller auf Cloud Run deployen
    OK  API-Poller laeuft (alle 60s)
...
==============================================================
 Deployment abgeschlossen!
==============================================================
 Grafana Dashboard:
   https://grafana-abc123-uc.a.run.app
```

---

## 5. Erstimport historischer Daten

Nach dem Deployment ist die Datenbank leer. Um historische CSV-Daten einzuspielen:

```powershell
# Cloud SQL IP abrufen
$SQL_IP = gcloud sql instances describe elevator-db --project=DEIN-PROJEKT --format="value(ipAddresses[0].ipAddress)"

# Umgebungsvariablen setzen
$env:DB_HOST = $SQL_IP
$env:DB_PORT = "5432"
$env:DB_NAME = "elevator_db"
$env:DB_USER = "postgres"
$env:DB_PASSWORD = "ElevatorHN2024!"
$env:DB_SSLMODE = "disable"

# CSV-Historikdaten importieren
.\venv\Scripts\python.exe csv_importer.py

# DWD-Wetterdaten der letzten 30 Tage nachholen
.\venv\Scripts\python.exe dwd_history_importer.py --range recent
```

---

## 6. Grafana aufrufen

Die URL erhältst du am Ende des Deployments. Format:
```
https://grafana-XXXXXXXX-uc.a.run.app
```

Login: **admin / admin**

> Nach dem ersten Login Passwort ändern:
> *Profile → Change Password*

### Grafana-URL nachträglich abrufen

```powershell
gcloud run services describe grafana --region=us-central1 --project=DEIN-PROJEKT --format="value(status.url)"
```

---

## 7. Betrieb überwachen

### Live-Logs anzeigen

```powershell
# API-Poller (Aufzugsdaten)
gcloud run services logs tail api-poller --region=us-central1 --project=DEIN-PROJEKT

# DWD-Poller (Wetterdaten)
gcloud run services logs tail dwd-poller --region=us-central1 --project=DEIN-PROJEKT

# Grafana
gcloud run services logs tail grafana --region=us-central1 --project=DEIN-PROJEKT
```

### Status aller Services

```powershell
gcloud run services list --region=us-central1 --project=DEIN-PROJEKT
```

### Cloud SQL Status

```powershell
gcloud sql instances describe elevator-db --project=DEIN-PROJEKT --format="value(state)"
```

### Letzten Forecast-Job prüfen

```powershell
gcloud run jobs executions list --job=forecast-job --region=us-central1 --project=DEIN-PROJEKT
```

### Direkt mit Datenbank verbinden (von lokal)

```powershell
$SQL_IP = gcloud sql instances describe elevator-db --project=DEIN-PROJEKT --format="value(ipAddresses[0].ipAddress)"
$env:PGPASSWORD = "ElevatorHN2024!"
psql -h $SQL_IP -U postgres -d elevator_db
```

---

## 8. Kosten im Blick behalten

### Geschätzte monatliche Kosten

| Ressource | Konfiguration | Kosten/Monat |
|-----------|---------------|--------------|
| Cloud SQL | db-f1-micro, 10 GB SSD | ~$10 |
| Cloud Run – Grafana | min 1, 1 vCPU / 1 GiB | ~$4 |
| Cloud Run – 3x Poller | min 1, 1 vCPU / 0.5 GiB je | ~$6 |
| Cloud Run Jobs | 2 Jobs täglich, kurz | ~$0.10 |
| Cloud Scheduler | 2 Jobs | kostenlos (unter Free Tier) |
| **Gesamt** | | **~$20/Monat** |

Mit $300 Free Trial: **~15 Monate Laufzeit**.

### Kosten im GCP Portal prüfen

1. https://console.cloud.google.com/billing
2. Projekt auswählen → **Cost breakdown**

### Kosten reduzieren (wenn Projekt pausiert)

```powershell
# Alle Poller auf 0 Instanzen skalieren (kein Traffic = keine Kosten)
gcloud run services update api-poller --min-instances=0 --region=us-central1
gcloud run services update extended-poller --min-instances=0 --region=us-central1
gcloud run services update dwd-poller --min-instances=0 --region=us-central1

# Cloud SQL pausieren (DB-Instanz stoppen)
gcloud sql instances patch elevator-db --activation-policy=NEVER --project=DEIN-PROJEKT
```

### Reaktivieren

```powershell
gcloud run services update api-poller --min-instances=1 --no-cpu-throttling --region=us-central1
gcloud sql instances patch elevator-db --activation-policy=ALWAYS --project=DEIN-PROJEKT
```

---

## 9. Häufige Fehler

### "Billing is not enabled"

Billing ist nicht mit dem Projekt verknüpft.
→ https://console.cloud.google.com/billing/projects → Projekt verknüpfen

### "API not enabled"

Eine API wurde noch nicht aktiviert.
```powershell
gcloud services enable run.googleapis.com sqladmin.googleapis.com --project=DEIN-PROJEKT
```

### "psql nicht gefunden" beim Schema-Einspielen

```powershell
$env:PATH += ";C:\Program Files\PostgreSQL\16\bin"
psql --version
```

Falls noch nicht installiert: https://www.postgresql.org/download/windows/

### Cloud Run Service startet nicht (Health Check fehlt)

Unsere Poller haben `/health` auf Port 8080. Wenn Cloud Run den Service als
"unhealthy" markiert, Logs prüfen:
```powershell
gcloud run services logs read api-poller --region=us-central1 --limit=50
```

### JWT-Token abgelaufen (API gibt 401 zurück)

Neuen Token aus dem Elevision-Portal holen und Service aktualisieren:
```powershell
gcloud run services update api-poller `
    --update-env-vars="ELEVISION_JWT_TOKEN=NEUER_TOKEN" `
    --region=us-central1 `
    --project=DEIN-PROJEKT
```

---

## 10. Alles löschen

```powershell
gcloud projects delete DEIN-PROJEKT-ID
```

Löscht alles (Cloud SQL, Cloud Run, alle Daten) und stoppt alle Kosten.
**Nicht rückgängig zu machen** — vorher Daten sichern falls nötig.

Nur einzelne Ressourcen löschen:
```powershell
# Cloud SQL (teuerste Ressource)
gcloud sql instances delete elevator-db --project=DEIN-PROJEKT

# Cloud Run Services
gcloud run services delete grafana api-poller extended-poller dwd-poller --region=us-central1 --project=DEIN-PROJEKT
```

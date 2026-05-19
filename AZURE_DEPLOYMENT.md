# Azure Deployment – Smart Elevator Monitoring

Vollständige Schritt-für-Schritt-Anleitung für Azure for Students.  
Geschätzte Gesamtdauer: **25–35 Minuten** (davon ~20 Min. automatisch).  
Monatliche Kosten: **ca. 3–5 €** (gut im Rahmen des Student-Guthabens).

---

## Inhaltsverzeichnis

1. [Voraussetzungen installieren](#1-voraussetzungen-installieren)
2. [Azure-Konto vorbereiten](#2-azure-konto-vorbereiten)
3. [Deployment starten](#3-deployment-starten)
4. [Was das Script im Hintergrund tut](#4-was-das-script-im-hintergrund-tut)
5. [Nach dem Deployment: Erstimport](#5-nach-dem-deployment-erstimport)
6. [Grafana in Azure aufrufen](#6-grafana-in-azure-aufrufen)
7. [Laufenden Betrieb überwachen](#7-laufenden-betrieb-überwachen)
8. [Kosten im Blick behalten](#8-kosten-im-blick-behalten)
9. [Häufige Fehler und Lösungen](#9-häufige-fehler-und-lösungen)
10. [Alles wieder löschen](#10-alles-wieder-löschen)

---

## 1. Voraussetzungen installieren

Du brauchst drei Programme. Prüfe zuerst, ob sie schon vorhanden sind:

```powershell
az --version
docker --version
psql --version
```

### Azure CLI

Falls `az` nicht gefunden wird:

1. Öffne: https://aka.ms/installazurecliwindows
2. Lade den MSI-Installer herunter und führe ihn aus
3. **PowerShell neu starten** nach der Installation
4. Prüfen: `az --version` → sollte `azure-cli 2.x.x` zeigen

### Docker Desktop

Falls `docker` nicht gefunden wird:

1. Öffne: https://www.docker.com/products/docker-desktop/
2. Lade Docker Desktop für Windows herunter und installiere es
3. Nach der Installation Docker Desktop **starten** (Taskleiste → Wal-Icon muss grün sein)
4. Prüfen: `docker --version` → sollte `Docker version 25.x.x` zeigen

> **Wichtig:** Docker Desktop muss beim Deployment **laufen** – die Images werden
> lokal gebaut und dann nach Azure hochgeladen.

### PostgreSQL Client (psql)

Wird nur einmalig für das Schema-Einspielen benötigt.

Falls `psql` nicht gefunden wird:

1. Öffne: https://www.postgresql.org/download/windows/
2. Klicke auf **Download the installer** (EDB-Installer)
3. Wähle PostgreSQL 16, Windows x86-64
4. Im Installer: nur **"Command Line Tools"** auswählen reicht (kein Server nötig)
5. **PowerShell neu starten**
6. Prüfen: `psql --version` → sollte `psql (PostgreSQL) 16.x` zeigen

---

## 2. Azure-Konto vorbereiten

### Einloggen

```powershell
az login
```

Ein Browser-Fenster öffnet sich. Melde dich mit deinem **@hs-heilbronn.de** oder
**@outlook.de** Konto an, das mit Azure for Students verknüpft ist.

Nach dem Login zeigt das Terminal dein Konto an:

```
[
  {
    "name": "Azure for Students",
    "state": "Enabled",
    ...
  }
]
```

### Subscription prüfen

```powershell
az account show --query "{Name:name, ID:id, State:state}" -o table
```

Die Ausgabe sollte `Azure for Students` und `Enabled` zeigen. Falls mehrere
Subscriptions vorhanden sind:

```powershell
# Alle anzeigen
az account list -o table

# Die richtige aktivieren (ID aus der Liste oben)
az account set --subscription "DEINE-SUBSCRIPTION-ID"
```

### Script-Ausführung erlauben (einmalig)

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Mit `J` bestätigen.

---

## 3. Deployment starten

Wechsle in den Projektordner (falls nicht schon dort):

```powershell
cd "c:\Users\lenna\Downloads\Smart_Elevator-main (1)\Smart_Elevator-main"
```

Dann starten:

```powershell
.\azure-deploy.ps1
```

### Was du während des Deployments siehst

Das Script gibt dir laufend Feedback. So sieht ein erfolgreicher Durchlauf aus:

```
>>> Voraussetzungen pruefen
    OK  Azure CLI gefunden
    OK  Eingeloggt als: Azure for Students
    OK  Container Apps Extension bereit

>>> Resource Provider registrieren
    OK  Microsoft.ContainerRegistry (bereits registriert)
    ... Microsoft.DBforPostgreSQL wird registriert...
    OK  Microsoft.DBforPostgreSQL registriert
    ...

>>> Container Registry: elevatormonitoring
    OK  Registry: elevatormonitoring.azurecr.io

>>> Docker Images lokal bauen und nach Azure pushen
    ... Poller-Image lokal bauen (dauert 3-5 Minuten)...
    OK  Poller-Image gepusht
    OK  Grafana-Image gepusht

>>> PostgreSQL Flexible Server: elevator-db-hn
    ... Server wird erstellt (dauert 3-5 Minuten)...
    OK  Server erstellt
    OK  FQDN: elevator-db-hn.postgres.database.azure.com
    OK  TimescaleDB Allowlist gesetzt
    OK  shared_preload_libraries gesetzt
    ... Server neu starten damit Preload-Library aktiv wird...
    OK  Server neugestartet

>>> Datenbank-Schema einspielen
    OK  Schema eingespielt

>>> Container Apps Environment: elevator-cae
    OK  Environment erstellt

>>> Grafana deployen
    OK  Grafana: https://grafana.xyz123.westeurope.azurecontainerapps.io

>>> API-Poller deployen
    OK  API-Poller laeuft
    ...

==============================================================
 Deployment abgeschlossen!
==============================================================
 Grafana Dashboard:
   https://grafana.xyz123.westeurope.azurecontainerapps.io
   Login: admin / admin
```

> **Die URL am Ende aufschreiben** – das ist dein Grafana-Zugang in der Cloud.

### Wenn das Script nach dem Registry-Namen fragt

Falls der Name `elevatormonitoring` schon vergeben ist (globale Azure-Eindeutigkeit),
fragt das Script nach einem neuen Namen. Einfach z.B. `elevatormonitoring2` eingeben.

---

## 4. Was das Script im Hintergrund tut

| Schritt | Was wird erstellt | Warum |
|---------|-------------------|-------|
| Resource Group | `elevator-monitoring-rg` in `westeurope` | Container für alle Ressourcen |
| Container Registry | `elevatormonitoring.azurecr.io` | Private Docker-Registry für unsere Images |
| Docker Build & Push | `elevator-poller:latest`, `elevator-grafana:latest` | Images lokal gebaut, dann hochgeladen |
| PostgreSQL Flexible Server | `elevator-db-hn` (Standard_B1ms, 32 GB) | Managed TimescaleDB-Datenbank |
| TimescaleDB | Extension + Preload + Neustart | Hypertables für Zeitreihendaten |
| Schema | Alle Tabellen, Views, Indizes | Datenbankstruktur aus `schema.sql` |
| Container Apps Environment | `elevator-cae` | Gemeinsame Netzwerk-Umgebung für alle Container |
| Grafana | Container App, Port 3000, öffentlich | Dashboard erreichbar über HTTPS |
| api-poller | Container App, intern, alle 60s | Liest Aufzugsdaten von Elevision API |
| extended-poller | Container App, intern, 1–60min | Fehler, Türen, Statistiken |
| dwd-poller | Container App, intern, stündlich | Wetterdaten vom DWD |
| forecast-job | Scheduled Job, täglich 02:00 UTC | ML-Prognose (LightGBM) |
| alerter-job | Scheduled Job, täglich 07:00 UTC | Anomalie-Erkennung |

**Region `westeurope`:** Germanywestcentral unterstützt bei Azure for Students kein
PostgreSQL Flexible Server – deshalb wird westeurope (Amsterdam) verwendet.

---

## 5. Nach dem Deployment: Erstimport

Die Datenbank ist nach dem Deployment leer. Um historische CSV-Daten einzuspielen:

### CSV-Historikdaten importieren

Deine eigene IP muss temporär freigegeben werden:

```powershell
# Eigene IP ermitteln
$MY_IP = (Invoke-RestMethod "https://api.ipify.org")
Write-Host "Deine IP: $MY_IP"

# Firewall temporär öffnen
az postgres flexible-server firewall-rule create `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --rule-name LocalImport `
    --start-ip-address $MY_IP `
    --end-ip-address $MY_IP

# FQDN des Servers abrufen
$FQDN = az postgres flexible-server show `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --query "fullyQualifiedDomainName" -o tsv

Write-Host "Server: $FQDN"
```

CSV-Importer ausführen (verbindet sich direkt mit Azure-DB):

```powershell
$env:DB_HOST = $FQDN
$env:DB_PASSWORD = "ElevatorHN2024!"
$env:DB_SSLMODE = "require"

.\venv\Scripts\python.exe csv_importer.py
```

DWD-Historik der letzten 30 Tage nachholen:

```powershell
.\venv\Scripts\python.exe dwd_history_importer.py --range recent
```

Firewall-Regel danach wieder entfernen:

```powershell
az postgres flexible-server firewall-rule delete `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --rule-name LocalImport `
    --yes
```

---

## 6. Grafana in Azure aufrufen

Die URL hast du am Ende des Deployments erhalten. Format:

```
https://grafana.xyz123.westeurope.azurecontainerapps.io
```

Login: **admin / admin**

> Empfehlung: Passwort nach dem ersten Login unter
> *Profile → Change Password* ändern.

### Grafana-URL nachträglich abrufen

Falls du die URL nicht mehr hast:

```powershell
az containerapp show `
    --name grafana `
    --resource-group elevator-monitoring-rg `
    --query "properties.configuration.ingress.fqdn" -o tsv
```

---

## 7. Laufenden Betrieb überwachen

### Live-Logs der Container anzeigen

```powershell
# API-Poller (Aufzugsdaten)
az containerapp logs show `
    --name api-poller `
    --resource-group elevator-monitoring-rg `
    --follow

# Extended Poller (Fehler, Türen, Statistiken)
az containerapp logs show `
    --name extended-poller `
    --resource-group elevator-monitoring-rg `
    --follow

# DWD Wetter-Poller
az containerapp logs show `
    --name dwd-poller `
    --resource-group elevator-monitoring-rg `
    --follow

# Grafana
az containerapp logs show `
    --name grafana `
    --resource-group elevator-monitoring-rg `
    --follow
```

Strg+C zum Beenden des Log-Streams.

### Status aller Container Apps prüfen

```powershell
az containerapp list `
    --resource-group elevator-monitoring-rg `
    --query "[].{Name:name, Status:properties.runningStatus, Replicas:properties.latestRevisionName}" `
    -o table
```

### Letzten Forecast-Job prüfen

```powershell
az containerapp job execution list `
    --name forecast-job `
    --resource-group elevator-monitoring-rg `
    --query "[0].{Status:properties.status, Start:properties.startTime}" `
    -o table
```

### Datenbankverbindung testen (von lokal)

```powershell
$FQDN = az postgres flexible-server show `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --query "fullyQualifiedDomainName" -o tsv

$env:PGPASSWORD = "ElevatorHN2024!"
psql -h $FQDN -U pgadmin -d elevator_db --set=sslmode=require -c "\dt"
```

---

## 8. Kosten im Blick behalten

### Geschätzte monatliche Kosten

| Ressource | SKU | Kosten/Monat |
|-----------|-----|--------------|
| PostgreSQL Flexible Server | Standard_B1ms (Burstable) | ~$6 |
| Container Registry | Basic | ~$5 |
| Container Apps – Grafana | 0.5 vCPU / 1 GiB | ~$3 |
| Container Apps – Poller (3x) | 0.25 vCPU / 0.5 GiB | ~$4 |
| Scheduled Jobs | minimal | ~$0.50 |
| **Gesamt** | | **~$18–20/Monat** |

Azure for Students gibt **$100 Guthaben** – reicht für ca. **5 Monate**.

> Tipp: Wenn das Projekt nicht aktiv genutzt wird, einfach die Container Apps
> auf 0 Replicas skalieren oder alles löschen (Schritt 10).

### Kostenübersicht im Azure Portal

1. Öffne: https://portal.azure.com
2. Suche nach **"Cost Management"**
3. Wähle deine Subscription → **Cost analysis**

---

## 9. Häufige Fehler und Lösungen

### "Registry-Name nicht verfügbar"

Der Name `elevatormonitoring` ist global eindeutig. Das Script fragt nach einem
alternativen Namen. Einfach eine Zahl anhängen: `elevatormonitoring42`

### "Docker Build fehlgeschlagen"

Docker Desktop muss laufen. Prüfen:
```powershell
docker info
```
Falls Fehler: Docker Desktop in der Taskleiste öffnen und warten bis das Wal-Icon grün ist.

### "psql: connection refused" beim Schema-Einspielen

Die eigene IP ist noch nicht in der Firewall. Das Script macht das automatisch,
aber falls es manuell nötig ist:

```powershell
$MY_IP = (Invoke-RestMethod "https://api.ipify.org")
az postgres flexible-server firewall-rule create `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --rule-name TempAccess `
    --start-ip-address $MY_IP `
    --end-ip-address $MY_IP
```

### "TimescaleDB Extension konnte nicht erstellt werden"

Wenn `CREATE EXTENSION timescaledb` scheitert, wurde der Server-Neustart nicht
abgewartet. Schema manuell nochmal einspielen:

```powershell
$FQDN = az postgres flexible-server show `
    --resource-group elevator-monitoring-rg `
    --name elevator-db-hn `
    --query "fullyQualifiedDomainName" -o tsv

$env:PGPASSWORD = "ElevatorHN2024!"
psql -h $FQDN -U pgadmin -d elevator_db --set=sslmode=require -f schema.sql
```

### Grafana zeigt "No Data" für alle Panels

Der api-poller läuft, aber es sind noch keine Daten in der DB.
Logs prüfen:

```powershell
az containerapp logs show --name api-poller --resource-group elevator-monitoring-rg
```

Häufige Ursache: JWT-Token abgelaufen → neuen Token aus dem Elevision-Portal
holen und im Container aktualisieren:

```powershell
az containerapp secret set `
    --name api-poller `
    --resource-group elevator-monitoring-rg `
    --secrets "jwt-token=NEUER_TOKEN_HIER"

# Container neu starten damit neuer Token aktiv wird
az containerapp revision restart `
    --name api-poller `
    --resource-group elevator-monitoring-rg
```

### "Subscription quota exceeded"

Azure for Students hat CPU-Limits. Falls Container Apps nicht starten:

```powershell
# Aktuelle Quota prüfen
az vm list-usage --location westeurope --query "[?contains(name.value,'cores')]" -o table
```

Lösung: Region auf `northeurope` wechseln (in `azure-deploy.ps1` `$LOCATION` anpassen).

---

## 10. Alles wieder löschen

Um alle Azure-Ressourcen zu löschen und keine weiteren Kosten zu erzeugen:

```powershell
az group delete --name elevator-monitoring-rg --yes
```

> Das löscht **alles** in der Resource Group (DB, Container, Registry).
> Lokale Daten und Code bleiben unberührt.

Dauert ca. 5 Minuten. Danach ist das Guthaben wieder frei.

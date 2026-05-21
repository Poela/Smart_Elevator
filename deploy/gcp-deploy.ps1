# ==============================================================================
# Elevator Monitoring - Google Cloud Deployment
# Kompatibel mit Windows PowerShell 5.1
# Datenbank: Cloud SQL PostgreSQL 16 (persistent, managed, automatische Backups)
# Container:  Cloud Run (pollers dauerhaft, jobs geplant)
# Registry:   Docker Hub (bereits vorhanden)
# ==============================================================================
# Voraussetzungen:
#   1. gcloud CLI installiert (https://cloud.google.com/sdk/docs/install)
#   2. Docker Desktop laeuft
#   3. GCP-Projekt angelegt (console.cloud.google.com)
# Ausfuehren:
#   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\gcp-deploy.ps1
# ==============================================================================

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------------------------
# KONFIGURATION – HIER ANPASSEN
# ------------------------------------------------------------------------------
$PROJECT_ID        = "elevator-monitoring-496813"                    # z.B. "elevator-monitoring-123"
$REGION            = "us-central1"         # Empfohlen: us-central1 (guenstigste Region)
$SQL_INSTANCE      = "elevator-db"
$DB_NAME           = "elevator_db"
$DB_USER           = "postgres"            # Cloud SQL Standard-Admin-User
$DB_PASSWORD       = ""
$DOCKERHUB_USER    = "hiprabbit"                    # z.B. "hiprabbit"
$GRAFANA_IMAGE     = "elevator-grafana"
$POLLER_IMAGE      = "elevator-poller"

# DB-Passwort und JWT-Token aus .env lesen
if (Test-Path ".env") {
    foreach ($line in (Get-Content ".env")) {
        if ($line -match "^DB_PASSWORD=(.+)$")          { $DB_PASSWORD = $Matches[1] }
        if ($line -match "^ELEVISION_JWT_TOKEN=(.+)$")  { $JWT_TOKEN   = $Matches[1] }
    }
}
if (-not $DB_PASSWORD) {
    $DB_PASSWORD = Read-Host "Cloud SQL Passwort eingeben"
}
if (-not $JWT_TOKEN) {
    $JWT_TOKEN = Read-Host "Elevision JWT-Token eingeben"
}

# ------------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ------------------------------------------------------------------------------
function Write-Step($msg) { Write-Host ""; Write-Host ">>> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "    ... $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "    WARNUNG: $msg" -ForegroundColor Yellow }

function Stop-OnError($msg) {
    Write-Host ""
    Write-Host "  FEHLER: $msg" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 0. VORAUSSETZUNGEN
# ------------------------------------------------------------------------------
Write-Step "Voraussetzungen pruefen"

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Stop-OnError "gcloud CLI nicht gefunden. Installieren: https://cloud.google.com/sdk/docs/install"
}
Write-OK "gcloud CLI gefunden"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-OnError "Docker nicht gefunden. Docker Desktop starten."
}
Write-OK "Docker gefunden"

if (-not $PROJECT_ID) {
    $PROJECT_ID = Read-Host "GCP Project-ID eingeben (z.B. elevator-monitoring-123)"
}
if (-not $DOCKERHUB_USER) {
    $DOCKERHUB_USER = Read-Host "Docker Hub Benutzername eingeben"
}

# ------------------------------------------------------------------------------
# 1. GCP AUTHENTIFIZIERUNG & PROJEKT
# ------------------------------------------------------------------------------
Write-Step "GCP Authentifizierung"

$currentAccount = gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
if (-not $currentAccount) {
    Write-Info "Nicht eingeloggt - starte Browser-Login..."
    gcloud auth login
}
Write-OK "Eingeloggt als: $(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>$null)"

gcloud config set project $PROJECT_ID 2>$null
Write-OK "Projekt gesetzt: $PROJECT_ID"

# Billing pruefen (Pflicht fuer Cloud Run + Cloud SQL)
$billingEnabled = gcloud beta billing projects describe $PROJECT_ID --format="value(billingEnabled)" 2>$null
if ($billingEnabled -ne "True") {
    Write-Host ""
    Write-Host "  HINWEIS: Billing ist noch nicht aktiviert." -ForegroundColor Yellow
    Write-Host "  Oeffne: https://console.cloud.google.com/billing/projects" -ForegroundColor Yellow
    Write-Host "  Verknuepfe dein Projekt mit deinem Billing-Konto (\$300 Free Trial)." -ForegroundColor Yellow
    Read-Host "  Enter druecken wenn Billing aktiviert ist"
}

# ------------------------------------------------------------------------------
# 2. APIS AKTIVIEREN
# ------------------------------------------------------------------------------
Write-Step "GCP APIs aktivieren"

$apis = @(
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "sql-component.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com"
)
foreach ($api in $apis) {
    Write-Info "Aktiviere $api ..."
    gcloud services enable $api --project=$PROJECT_ID 2>$null
}
Write-OK "Alle APIs aktiviert"

# ------------------------------------------------------------------------------
# 3. CLOUD SQL INSTANZ (PostgreSQL 16, persistent, automatische Backups)
# ------------------------------------------------------------------------------
Write-Step "Cloud SQL Instanz: $SQL_INSTANCE"

$sqlExists = gcloud sql instances describe $SQL_INSTANCE --project=$PROJECT_ID --format="value(name)" 2>$null
if (-not $sqlExists) {
    Write-Info "Erstelle Cloud SQL Instanz (dauert 3-5 Minuten)..."
    gcloud sql instances create $SQL_INSTANCE `
        --database-version=POSTGRES_16 `
        --edition=ENTERPRISE `
        --tier=db-f1-micro `
        --region=$REGION `
        --storage-type=SSD `
        --storage-size=10GB `
        --storage-auto-increase `
        --backup `
        --backup-start-time=02:00 `
        --authorized-networks=0.0.0.0/0 `
        --root-password=$DB_PASSWORD `
        --project=$PROJECT_ID

    if ($LASTEXITCODE -ne 0) {
        Stop-OnError "Cloud SQL konnte nicht erstellt werden. Prüfe ob Billing aktiviert ist."
    }
    Write-OK "Cloud SQL Instanz erstellt"
} else {
    Write-OK "Cloud SQL Instanz existiert bereits"
}

# Public IP abrufen
$SQL_IP = gcloud sql instances describe $SQL_INSTANCE `
    --project=$PROJECT_ID `
    --format="value(ipAddresses[0].ipAddress)" 2>$null

if (-not $SQL_IP) {
    Stop-OnError "SQL IP konnte nicht abgerufen werden."
}
Write-OK "Cloud SQL IP: $SQL_IP"

# Connection Name fuer Cloud Run (format: project:region:instance)
$SQL_CONNECTION_NAME = gcloud sql instances describe $SQL_INSTANCE `
    --project=$PROJECT_ID `
    --format="value(connectionName)" 2>$null
Write-OK "Connection Name: $SQL_CONNECTION_NAME"

# ------------------------------------------------------------------------------
# 4. DATENBANK UND SCHEMA
# ------------------------------------------------------------------------------
Write-Step "Datenbank und Schema einrichten"

Write-Info "Datenbank '$DB_NAME' erstellen..."
gcloud sql databases create $DB_NAME `
    --instance=$SQL_INSTANCE `
    --project=$PROJECT_ID 2>$null
Write-OK "Datenbank bereit"

# psql suchen
$psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psqlCmd) {
    $psqlPaths = @(
        "C:\Program Files\PostgreSQL\16\bin\psql.exe",
        "C:\Program Files\PostgreSQL\15\bin\psql.exe",
        "C:\Program Files\PostgreSQL\17\bin\psql.exe"
    )
    foreach ($p in $psqlPaths) {
        if (Test-Path $p) {
            $env:PATH += ";$(Split-Path $p)"
            $psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
            break
        }
    }
}

if ($psqlCmd) {
    Write-Info "Spiele schema-gcp.sql ein..."
    $env:PGPASSWORD = $DB_PASSWORD
    psql -h $SQL_IP -U $DB_USER -d $DB_NAME -f database/schema-gcp.sql
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Write-OK "Schema eingespielt"
} else {
    Write-Host ""
    Write-Host "  psql nicht gefunden. Installieren: https://www.postgresql.org/download/windows/" -ForegroundColor Yellow
    Write-Host "  Dann manuell ausfuehren:" -ForegroundColor Yellow
    Write-Host "  `$env:PGPASSWORD='$DB_PASSWORD'" -ForegroundColor Yellow
    Write-Host "  psql -h $SQL_IP -U $DB_USER -d $DB_NAME -f database/schema-gcp.sql" -ForegroundColor Yellow
    Read-Host "  Enter druecken wenn Schema eingespielt wurde"
}

# ------------------------------------------------------------------------------
# 5. IMAGES FUER CLOUD RUN NEU BAUEN (linux/amd64 erforderlich)
# Cloud Run unterstuetzt keine Multi-Arch OCI Manifests – explizit amd64 setzen.
# ------------------------------------------------------------------------------
Write-Step "Docker Images fuer Cloud Run bauen und pushen (linux/amd64)"

$GRAFANA_FULL = "docker.io/$DOCKERHUB_USER/${GRAFANA_IMAGE}:latest"
$POLLER_FULL  = "docker.io/$DOCKERHUB_USER/${POLLER_IMAGE}:latest"

Write-Info "Poller-Image bauen (linux/amd64, kein Provenance/SBOM)..."
docker build --platform=linux/amd64 --provenance=false --sbom=false -f deploy/Dockerfile -t $POLLER_FULL .
if ($LASTEXITCODE -ne 0) { Stop-OnError "Docker Build Poller fehlgeschlagen" }
Write-Info "Poller-Image pushen..."
docker push $POLLER_FULL
if ($LASTEXITCODE -ne 0) { Stop-OnError "Docker Push Poller fehlgeschlagen" }
Write-OK "Poller-Image gepusht: $POLLER_FULL"

Write-Info "Grafana-Image bauen (linux/amd64, kein Provenance/SBOM)..."
docker build --platform=linux/amd64 --provenance=false --sbom=false -f deploy/Dockerfile.grafana -t $GRAFANA_FULL .
if ($LASTEXITCODE -ne 0) { Stop-OnError "Docker Build Grafana fehlgeschlagen" }
Write-Info "Grafana-Image pushen..."
docker push $GRAFANA_FULL
if ($LASTEXITCODE -ne 0) { Stop-OnError "Docker Push Grafana fehlgeschlagen" }
Write-OK "Grafana-Image gepusht: $GRAFANA_FULL"

# ------------------------------------------------------------------------------
# 6. CLOUD RUN: GRAFANA (oeffentlich erreichbar)
# ------------------------------------------------------------------------------
Write-Step "Grafana auf Cloud Run deployen"

gcloud run deploy grafana `
    --image=$GRAFANA_FULL `
    --region=$REGION `
    --platform=managed `
    --allow-unauthenticated `
    --port=3000 `
    --min-instances=1 `
    --cpu=1 `
    --memory=1Gi `
    --set-env-vars="GF_SECURITY_ADMIN_USER=admin,GF_SECURITY_ADMIN_PASSWORD=admin,GF_POSTGRES_HOST=$SQL_IP,GF_POSTGRES_USER=$DB_USER,GF_POSTGRES_DB=$DB_NAME,GF_POSTGRES_SSLMODE=disable,GF_POSTGRES_PASSWORD=$DB_PASSWORD,GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/elevator_dashboard.json" `
    --project=$PROJECT_ID

$GRAFANA_URL = gcloud run services describe grafana `
    --region=$REGION `
    --project=$PROJECT_ID `
    --format="value(status.url)" 2>$null
Write-OK "Grafana: $GRAFANA_URL"

# ------------------------------------------------------------------------------
# 7. CLOUD RUN: API-POLLER (dauerhaft laufend, alle 60s)
# ------------------------------------------------------------------------------
Write-Step "API-Poller auf Cloud Run deployen"

gcloud run deploy api-poller `
    --image=$POLLER_FULL `
    --region=$REGION `
    --platform=managed `
    --no-allow-unauthenticated `
    --port=8080 `
    --min-instances=1 `
    --cpu=1 `
    --memory=512Mi `
    --no-cpu-throttling `
    --command="python" `
    --args="api_poller.py" `
    --set-env-vars="DB_HOST=$SQL_IP,DB_PORT=5432,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,DB_SSLMODE=disable,ELEVISION_API_BASE=https://api.elevision.de,ELEVISION_JWT_TOKEN=$JWT_TOKEN,LOG_LEVEL=INFO,METRICS_PORT=8080" `
    --project=$PROJECT_ID

Write-OK "API-Poller laeuft (alle 60s)"

# ------------------------------------------------------------------------------
# 8. CLOUD RUN: EXTENDED POLLER
# ------------------------------------------------------------------------------
Write-Step "Extended Poller auf Cloud Run deployen"

gcloud run deploy extended-poller `
    --image=$POLLER_FULL `
    --region=$REGION `
    --platform=managed `
    --no-allow-unauthenticated `
    --port=8081 `
    --min-instances=1 `
    --cpu=1 `
    --memory=512Mi `
    --no-cpu-throttling `
    --command="python" `
    --args="elevision_extended_poller.py" `
    --set-env-vars="DB_HOST=$SQL_IP,DB_PORT=5432,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,DB_SSLMODE=disable,ELEVISION_API_BASE=https://api.elevision.de,ELEVISION_JWT_TOKEN=$JWT_TOKEN,LOG_LEVEL=INFO,EXT_METRICS_PORT=8081" `
    --project=$PROJECT_ID

Write-OK "Extended Poller laeuft"

# ------------------------------------------------------------------------------
# 9. CLOUD RUN JOB: DWD-POLLER (stuendlich per Cloud Scheduler)
# dwd_poller.py hat keinen HTTP-Server → Cloud Run Job statt Service
# ------------------------------------------------------------------------------
Write-Step "DWD-Wetter-Poller Job erstellen"

gcloud run jobs create dwd-poller-job `
    --image=$POLLER_FULL `
    --region=$REGION `
    --command="python" `
    --args="dwd_poller.py" `
    --cpu=1 `
    --memory=512Mi `
    --max-retries=2 `
    --task-timeout=300s `
    --set-env-vars="DB_HOST=$SQL_IP,DB_PORT=5432,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,DB_SSLMODE=disable,DWD_STATION_ID=10729" `
    --project=$PROJECT_ID 2>$null
Write-OK "DWD-Poller Job erstellt (wird stuendlich ausgefuehrt)"

# ------------------------------------------------------------------------------
# 10. CLOUD RUN JOBS: FORECAST + ALERTER
# ------------------------------------------------------------------------------
Write-Step "ML-Forecast Job erstellen"

gcloud run jobs create forecast-job `
    --image=$POLLER_FULL `
    --region=$REGION `
    --command="python" `
    --args="forecast_service.py" `
    --cpu=1 `
    --memory=1Gi `
    --max-retries=1 `
    --task-timeout=1800s `
    --set-env-vars="DB_HOST=$SQL_IP,DB_PORT=5432,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,DB_SSLMODE=disable,FORECAST_HORIZON_DAYS=14,FORECAST_HISTORY_DAYS=365" `
    --project=$PROJECT_ID 2>$null
Write-OK "Forecast-Job erstellt"

Write-Step "Anomalie-Alerter Job erstellen"

gcloud run jobs create alerter-job `
    --image=$POLLER_FULL `
    --region=$REGION `
    --command="python" `
    --args="anomaly_alerter.py,--days,1" `
    --cpu=1 `
    --memory=512Mi `
    --max-retries=1 `
    --task-timeout=600s `
    --set-env-vars="DB_HOST=$SQL_IP,DB_PORT=5432,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,DB_SSLMODE=disable,ALERT_Z_CRITICAL=2.0,ALERT_Z_WARNING=1.5" `
    --project=$PROJECT_ID 2>$null
Write-OK "Alerter-Job erstellt"

# ------------------------------------------------------------------------------
# 11. CLOUD SCHEDULER: JOBS TAEGLICH AUSFUEHREN
# ------------------------------------------------------------------------------
Write-Step "Cloud Scheduler einrichten"

# Service Account fuer Scheduler-Ausfuehrung
$SA_NAME = "elevator-scheduler"
$SA_EMAIL = "$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

$saExists = gcloud iam service-accounts describe $SA_EMAIL --project=$PROJECT_ID --format="value(email)" 2>$null
if (-not $saExists) {
    gcloud iam service-accounts create $SA_NAME `
        --display-name="Elevator Scheduler" `
        --project=$PROJECT_ID 2>$null
    gcloud projects add-iam-policy-binding $PROJECT_ID `
        --member="serviceAccount:$SA_EMAIL" `
        --role="roles/run.invoker" 2>$null
    Write-OK "Service Account erstellt: $SA_EMAIL"
} else {
    Write-OK "Service Account existiert bereits"
}

# DWD: stuendlich
gcloud scheduler jobs create http dwd-trigger `
    --location=$REGION `
    --schedule="0 * * * *" `
    --uri="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/dwd-poller-job:run" `
    --message-body="{}" `
    --oauth-service-account-email=$SA_EMAIL `
    --project=$PROJECT_ID 2>$null
Write-OK "DWD-Poller: stuendlich"

# Forecast: taeglich 02:00 UTC (= 04:00 MESZ)
gcloud scheduler jobs create http forecast-trigger `
    --location=$REGION `
    --schedule="0 2 * * *" `
    --uri="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/forecast-job:run" `
    --message-body="{}" `
    --oauth-service-account-email=$SA_EMAIL `
    --project=$PROJECT_ID 2>$null
Write-OK "Forecast: taeglich 02:00 UTC"

# Alerter: taeglich 07:00 UTC (= 09:00 MESZ)
gcloud scheduler jobs create http alerter-trigger `
    --location=$REGION `
    --schedule="0 7 * * *" `
    --uri="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/alerter-job:run" `
    --message-body="{}" `
    --oauth-service-account-email=$SA_EMAIL `
    --project=$PROJECT_ID 2>$null
Write-OK "Alerter: taeglich 07:00 UTC"

# ------------------------------------------------------------------------------
# ZUSAMMENFASSUNG
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " Deployment abgeschlossen!" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " Grafana Dashboard:" -ForegroundColor White
Write-Host "   $GRAFANA_URL" -ForegroundColor Yellow
Write-Host "   Login: admin / admin" -ForegroundColor Gray
Write-Host ""
Write-Host " Datenbank (Cloud SQL, persistent):" -ForegroundColor White
Write-Host "   IP:   $SQL_IP" -ForegroundColor Gray
Write-Host "   DB:   $DB_NAME  |  User: $DB_USER" -ForegroundColor Gray
Write-Host ""
Write-Host " Laufende Cloud Run Services:" -ForegroundColor White
Write-Host "   grafana         (oeffentlich, min. 1 Instanz)" -ForegroundColor Gray
Write-Host "   api-poller      (intern, dauerhaft, alle 60s)" -ForegroundColor Gray
Write-Host "   extended-poller (intern, dauerhaft)" -ForegroundColor Gray
Write-Host ""
Write-Host " Geplante Jobs (Cloud Scheduler):" -ForegroundColor White
Write-Host "   dwd-poller-job  (stuendlich, 0 * * * *)" -ForegroundColor Gray
Write-Host "   forecast-job    (taeglich 02:00 UTC)" -ForegroundColor Gray
Write-Host "   alerter-job     (taeglich 07:00 UTC)" -ForegroundColor Gray
Write-Host ""
Write-Host " Logs anzeigen:" -ForegroundColor White
Write-Host "   gcloud run services logs read api-poller --region=$REGION --project=$PROJECT_ID" -ForegroundColor Gray
Write-Host "   gcloud run services logs tail api-poller --region=$REGION --project=$PROJECT_ID" -ForegroundColor Gray
Write-Host ""
Write-Host " Naechster Schritt - Erstimport (einmalig):" -ForegroundColor White
Write-Host "   Siehe GCP_DEPLOYMENT.md Abschnitt 5" -ForegroundColor Gray
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan

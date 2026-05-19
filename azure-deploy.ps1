# ==============================================================================
# Elevator Monitoring - Azure Deployment
# Kompatibel mit Windows PowerShell 5.1
# Registry:  Docker Hub  (ACR per Policy gesperrt bei Azure for Students)
# Datenbank: TimescaleDB als Container App (PostgreSQL Flexible Server gesperrt)
# ==============================================================================
# Ausfuehren:
#   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\azure-deploy.ps1
# ==============================================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# KONFIGURATION
# ------------------------------------------------------------------------------
$RESOURCE_GROUP      = "elevator-monitoring-rg"
$LOCATION            = "eastus"
$CONTAINER_ENV       = "elevator-cae"
$DB_NAME             = "elevator_db"
$POSTGRES_ADMIN      = "pgadmin"
$POSTGRES_PASSWORD   = "ElevatorHN2024!"
$POLLER_IMAGE        = "elevator-poller"
$GRAFANA_IMAGE       = "elevator-grafana"
$TIMESCALEDB_IMAGE   = "elevator-timescaledb"

# Docker Hub – leer lassen, Script fragt dann interaktiv
$DOCKERHUB_USER  = ""
$DOCKERHUB_TOKEN = ""

# JWT-Token aus .env lesen
$JWT_TOKEN = ""
if (Test-Path ".env") {
    foreach ($line in (Get-Content ".env")) {
        if ($line -match "^ELEVISION_JWT_TOKEN=(.+)$") { $JWT_TOKEN = $Matches[1]; break }
    }
}
if (-not $JWT_TOKEN) {
    Write-Warning "ELEVISION_JWT_TOKEN nicht in .env gefunden."
    $JWT_TOKEN = Read-Host "JWT-Token eingeben (oder Enter fuer leer)"
}

# ------------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ------------------------------------------------------------------------------
function Write-Step($msg) { Write-Host ""; Write-Host ">>> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "    ... $msg" -ForegroundColor Gray }

function Invoke-DockerPush($image) {
    $maxRetries = 5
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Info "Push-Versuch $i von $maxRetries : $image"
        docker push $image
        if ($LASTEXITCODE -eq 0) { return }
        if ($i -lt $maxRetries) {
            Write-Host "    WARNUNG: Push fehlgeschlagen, warte 10s und versuche erneut..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        }
    }
    Write-Error "Docker Push nach $maxRetries Versuchen fehlgeschlagen: $image"
    exit 1
}

# ------------------------------------------------------------------------------
# 0. VORAUSSETZUNGEN
# ------------------------------------------------------------------------------
Write-Step "Voraussetzungen pruefen"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI nicht gefunden. Installieren: https://aka.ms/installazurecliwindows"
    exit 1
}
Write-OK "Azure CLI gefunden"

$accountJson = az account show -o json 2>$null
if (-not $accountJson) { az login; $accountJson = az account show -o json }
$account = $accountJson | ConvertFrom-Json
Write-OK "Eingeloggt als: $($account.name)"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker nicht gefunden. Docker Desktop installieren: https://www.docker.com/products/docker-desktop/"
    exit 1
}
Write-OK "Docker gefunden"

if (-not $DOCKERHUB_USER)  { $DOCKERHUB_USER  = Read-Host "Docker Hub Benutzername" }
if (-not $DOCKERHUB_TOKEN) { $DOCKERHUB_TOKEN = Read-Host "Docker Hub Access Token" }

Write-Info "Container Apps Extension pruefen..."
az extension add --name containerapp --upgrade --only-show-errors 2>$null
Write-OK "Container Apps Extension bereit"

# ------------------------------------------------------------------------------
# 1. RESOURCE PROVIDER
# ------------------------------------------------------------------------------
Write-Step "Azure Resource Provider registrieren"
foreach ($p in @("Microsoft.App","Microsoft.OperationalInsights","Microsoft.Storage")) {
    $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
    if ($state -eq "Registered") {
        Write-OK "$p (bereits registriert)"
    } else {
        Write-Info "$p wird registriert..."
        az provider register --namespace $p --output none
    }
}
Write-Info "Warte bis alle Provider bereit sind..."
foreach ($p in @("Microsoft.App","Microsoft.OperationalInsights","Microsoft.Storage")) {
    $waited = 0
    do {
        Start-Sleep -Seconds 5; $waited += 5
        $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
    } while ($state -ne "Registered" -and $waited -lt 120)
    if ($state -eq "Registered") { Write-OK "$p registriert" }
    else { Write-Host "  WARNUNG: $p noch nicht bereit" -ForegroundColor Yellow }
}

# ------------------------------------------------------------------------------
# 2. RESOURCE GROUP
# ------------------------------------------------------------------------------
Write-Step "Resource Group: $RESOURCE_GROUP"

$existingRg = $null
try { $existingRg = az group show --name $RESOURCE_GROUP -o json 2>$null } catch {}
if ($existingRg) {
    $rgState = ($existingRg | ConvertFrom-Json).properties.provisioningState
    if ($rgState -eq "Deleting") {
        Write-Host "  Resource Group wird geloescht - warte..." -ForegroundColor Yellow
        $waited = 0
        do {
            Start-Sleep -Seconds 15; $waited += 15
            try { $existingRg = az group show --name $RESOURCE_GROUP -o json 2>$null } catch { $existingRg = $null }
        } while ($existingRg -and $waited -lt 300)
    } else {
        Write-OK "Resource Group existiert bereits (State: $rgState)"
    }
}
az group create --name $RESOURCE_GROUP --location $LOCATION --output none
Write-OK "Resource Group bereit in $LOCATION"

# ------------------------------------------------------------------------------
# 3. DOCKER IMAGES BAUEN UND ZU DOCKER HUB PUSHEN
# ------------------------------------------------------------------------------
Write-Step "Docker Images bauen und zu Docker Hub pushen"

$REGISTRY_SERVER    = "docker.io"
$POLLER_FULL_IMAGE  = "$DOCKERHUB_USER/${POLLER_IMAGE}:latest"
$GRAFANA_FULL_IMAGE = "$DOCKERHUB_USER/${GRAFANA_IMAGE}:latest"
$TSDB_FULL_IMAGE    = "$DOCKERHUB_USER/${TIMESCALEDB_IMAGE}:latest"

Write-Info "Einloggen in Docker Hub..."
$DOCKERHUB_TOKEN | docker login docker.io --username $DOCKERHUB_USER --password-stdin
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Hub Login fehlgeschlagen."; exit 1 }
Write-OK "Docker Hub Login erfolgreich"

Write-Info "Poller-Image bauen..."
docker build -f Dockerfile -t $POLLER_FULL_IMAGE .
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Build fehlgeschlagen"; exit 1 }
Write-Info "Poller-Image hochladen..."
Invoke-DockerPush $POLLER_FULL_IMAGE
Write-OK "Poller-Image gepusht: $POLLER_FULL_IMAGE"

Write-Info "Grafana-Image bauen..."
docker build -f Dockerfile.grafana -t $GRAFANA_FULL_IMAGE .
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Build fehlgeschlagen"; exit 1 }
Write-Info "Grafana-Image hochladen..."
Invoke-DockerPush $GRAFANA_FULL_IMAGE
Write-OK "Grafana-Image gepusht: $GRAFANA_FULL_IMAGE"

Write-Info "TimescaleDB-Image bauen (mit Schema)..."
docker build -f Dockerfile.timescaledb -t $TSDB_FULL_IMAGE .
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Build fehlgeschlagen"; exit 1 }
Write-Info "TimescaleDB-Image hochladen..."
Invoke-DockerPush $TSDB_FULL_IMAGE
Write-OK "TimescaleDB-Image gepusht: $TSDB_FULL_IMAGE"

# ------------------------------------------------------------------------------
# 4. CONTAINER APPS ENVIRONMENT
# ------------------------------------------------------------------------------
Write-Step "Container Apps Environment: $CONTAINER_ENV"

$envExists = $null
try { $envExists = az containerapp env show --name $CONTAINER_ENV --resource-group $RESOURCE_GROUP -o json 2>$null } catch {}
if (-not $envExists) {
    Write-Info "Erstelle Environment (ohne Log Analytics - in Azure for Students gesperrt)..."
    az containerapp env create `
        --name $CONTAINER_ENV `
        --resource-group $RESOURCE_GROUP `
        --location $LOCATION `
        --logs-destination none `
        --output none

    # Pruefen ob Environment wirklich erstellt wurde
    $envCheck = $null
    try { $envCheck = az containerapp env show --name $CONTAINER_ENV --resource-group $RESOURCE_GROUP -o json 2>$null } catch {}
    if (-not $envCheck) {
        Write-Host ""
        Write-Host "  FEHLER: Container Apps Environment konnte nicht erstellt werden." -ForegroundColor Red
        Write-Host "  Region '$LOCATION' ist moeglicherweise fuer Container Apps gesperrt." -ForegroundColor Yellow
        exit 1
    }
    Write-OK "Environment erstellt"
} else {
    Write-OK "Environment existiert bereits"
}

# ------------------------------------------------------------------------------
# 5. TIMESCALEDB CONTAINER APP
# Ephemerer Storage (kein Azure Files noetig – Storage Accounts ebenfalls gesperrt).
# min-replicas=1 haelt den Container dauerhaft am Laufen, Daten bleiben erhalten
# solange der Container nicht neu gestartet wird.
# ------------------------------------------------------------------------------
Write-Step "TimescaleDB Container App deployen"

$tsdbExists = $null
try { $tsdbExists = az containerapp show --name timescaledb --resource-group $RESOURCE_GROUP -o json 2>$null } catch {}
if (-not $tsdbExists) {
    az containerapp create `
        --name timescaledb `
        --resource-group $RESOURCE_GROUP `
        --environment $CONTAINER_ENV `
        --image $TSDB_FULL_IMAGE `
        --registry-server docker.io `
        --registry-username $DOCKERHUB_USER `
        --registry-password $DOCKERHUB_TOKEN `
        --min-replicas 1 `
        --max-replicas 1 `
        --cpu 0.5 `
        --memory 1.0Gi `
        --ingress internal `
        --transport tcp `
        --target-port 5432 `
        --secrets "pg-password=$POSTGRES_PASSWORD" `
        --env-vars `
            "POSTGRES_USER=$POSTGRES_ADMIN" `
            "POSTGRES_PASSWORD=secretref:pg-password" `
            "POSTGRES_DB=$DB_NAME" `
        --output none
    Write-OK "TimescaleDB Container App erstellt"
} else {
    Write-OK "TimescaleDB Container App existiert bereits"
}

Write-Info "Warte 60 Sekunden bis TimescaleDB hochgefahren ist und Schema eingespielt hat..."
Start-Sleep -Seconds 60

$POSTGRES_FQDN = az containerapp show `
    --name timescaledb `
    --resource-group $RESOURCE_GROUP `
    --query "properties.configuration.ingress.fqdn" -o tsv
Write-OK "TimescaleDB intern erreichbar unter: ${POSTGRES_FQDN}:5432"

# ------------------------------------------------------------------------------
# 7. UMGEBUNGSVARIABLEN fuer alle Poller
# ------------------------------------------------------------------------------
$DB_ENV_VARS = @(
    "DB_HOST=$POSTGRES_FQDN",
    "DB_PORT=5432",
    "DB_NAME=$DB_NAME",
    "DB_USER=$POSTGRES_ADMIN",
    "DB_SSLMODE=disable",
    "ELEVISION_API_BASE=https://api.elevision.de",
    "LOG_LEVEL=INFO"
)
$DB_SECRETS = @(
    "db-password=$POSTGRES_PASSWORD",
    "jwt-token=$JWT_TOKEN",
    "dockerhub-token=$DOCKERHUB_TOKEN"
)
$DB_SECRET_REFS = @(
    "DB_PASSWORD=secretref:db-password",
    "ELEVISION_JWT_TOKEN=secretref:jwt-token"
)

# ------------------------------------------------------------------------------
# 8. GRAFANA CONTAINER APP
# ------------------------------------------------------------------------------
Write-Step "Grafana deployen"
az containerapp create `
    --name grafana `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $GRAFANA_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --target-port 3000 `
    --ingress external `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.5 `
    --memory 1.0Gi `
    --secrets "gf-postgres-password=$POSTGRES_PASSWORD" `
    --env-vars `
        "GF_SECURITY_ADMIN_USER=admin" `
        "GF_SECURITY_ADMIN_PASSWORD=admin" `
        "GF_POSTGRES_HOST=$POSTGRES_FQDN" `
        "GF_POSTGRES_USER=$POSTGRES_ADMIN" `
        "GF_POSTGRES_DB=$DB_NAME" `
        "GF_POSTGRES_SSLMODE=disable" `
        "GF_POSTGRES_PASSWORD=secretref:gf-postgres-password" `
        "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/elevator_dashboard.json" `
    --output none
$GRAFANA_URL = az containerapp show `
    --name grafana `
    --resource-group $RESOURCE_GROUP `
    --query "properties.configuration.ingress.fqdn" -o tsv
Write-OK "Grafana: https://$GRAFANA_URL"

# ------------------------------------------------------------------------------
# 9. API-POLLER
# ------------------------------------------------------------------------------
Write-Step "API-Poller deployen"
az containerapp create `
    --name api-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $POLLER_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --command "python" "api_poller.py" `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --ingress internal `
    --target-port 8080 `
    --secrets $DB_SECRETS `
    --env-vars ($DB_ENV_VARS + $DB_SECRET_REFS + @("METRICS_PORT=8080","CB_FAILURE_THRESHOLD=5","CB_RECOVERY_TIMEOUT_SEC=60")) `
    --output none
Write-OK "API-Poller laeuft"

# ------------------------------------------------------------------------------
# 10. EXTENDED POLLER
# ------------------------------------------------------------------------------
Write-Step "Extended Poller deployen"
az containerapp create `
    --name extended-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $POLLER_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --command "python" "elevision_extended_poller.py" `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --ingress internal `
    --target-port 8081 `
    --secrets $DB_SECRETS `
    --env-vars ($DB_ENV_VARS + $DB_SECRET_REFS + @("EXT_METRICS_PORT=8081")) `
    --output none
Write-OK "Extended Poller laeuft"

# ------------------------------------------------------------------------------
# 11. DWD-POLLER
# ------------------------------------------------------------------------------
Write-Step "DWD-Wetter-Poller deployen"
az containerapp create `
    --name dwd-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $POLLER_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --command "python" "dwd_poller.py" "--loop" `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --secrets @("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password","DWD_STATION_ID=10729","DWD_POLL_INTERVAL_SEC=3600")) `
    --output none
Write-OK "DWD-Poller laeuft"

# ------------------------------------------------------------------------------
# 12. ML-FORECAST JOB
# ------------------------------------------------------------------------------
Write-Step "ML-Forecast Job deployen"
az containerapp job create `
    --name forecast-job `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $POLLER_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --trigger-type Schedule `
    --cron-expression "0 2 * * *" `
    --replica-timeout 1800 `
    --replica-retry-limit 1 `
    --replica-completion-count 1 `
    --parallelism 1 `
    --cpu 0.5 `
    --memory 1.0Gi `
    --command "python" "forecast_service.py" `
    --secrets @("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password","FORECAST_HORIZON_DAYS=14","FORECAST_HISTORY_DAYS=365")) `
    --output none
Write-OK "Forecast-Job registriert (taeglich 02:00 UTC)"

# ------------------------------------------------------------------------------
# 13. ANOMALIE-ALERTER JOB
# ------------------------------------------------------------------------------
Write-Step "Anomalie-Alerter Job deployen"
az containerapp job create `
    --name alerter-job `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image $POLLER_FULL_IMAGE `
    --registry-server $REGISTRY_SERVER `
    --registry-username $DOCKERHUB_USER `
    --registry-password $DOCKERHUB_TOKEN `
    --trigger-type Schedule `
    --cron-expression "0 7 * * *" `
    --replica-timeout 600 `
    --replica-retry-limit 1 `
    --replica-completion-count 1 `
    --parallelism 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --command "python" "anomaly_alerter.py" "--days" "1" `
    --secrets @("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password","ALERT_Z_CRITICAL=2.0","ALERT_Z_WARNING=1.5")) `
    --output none
Write-OK "Alerter-Job registriert (taeglich 07:00 UTC)"

# ------------------------------------------------------------------------------
# ZUSAMMENFASSUNG
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " Deployment abgeschlossen!" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " Grafana Dashboard:" -ForegroundColor White
Write-Host "   https://$GRAFANA_URL" -ForegroundColor Yellow
Write-Host "   Login: admin / admin" -ForegroundColor Gray
Write-Host ""
Write-Host " Datenbank (intern):" -ForegroundColor White
Write-Host "   Host: $POSTGRES_FQDN" -ForegroundColor Gray
Write-Host "   DB:   $DB_NAME  |  User: $POSTGRES_ADMIN" -ForegroundColor Gray
Write-Host ""
Write-Host " Laufende Container Apps:" -ForegroundColor White
Write-Host "   timescaledb     (Datenbank, persistent via Azure Files)" -ForegroundColor Gray
Write-Host "   grafana         (Dashboard, oeffentlich erreichbar)" -ForegroundColor Gray
Write-Host "   api-poller      (Aufzugsdaten, alle 60 s)" -ForegroundColor Gray
Write-Host "   extended-poller (Fehler/Tueren/Statistiken)" -ForegroundColor Gray
Write-Host "   dwd-poller      (Wetterdaten, stuendlich)" -ForegroundColor Gray
Write-Host ""
Write-Host " Geplante Jobs:" -ForegroundColor White
Write-Host "   forecast-job  (taeglich 02:00 UTC)" -ForegroundColor Gray
Write-Host "   alerter-job   (taeglich 07:00 UTC)" -ForegroundColor Gray
Write-Host ""
Write-Host " Logs anzeigen:" -ForegroundColor White
Write-Host "   az containerapp logs show --name api-poller --resource-group $RESOURCE_GROUP --follow" -ForegroundColor Gray
Write-Host "   az containerapp logs show --name timescaledb --resource-group $RESOURCE_GROUP --follow" -ForegroundColor Gray
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan

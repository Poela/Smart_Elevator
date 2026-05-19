# ==============================================================================
# Elevator Monitoring - Azure Deployment
# Kompatibel mit Windows PowerShell 5.1
# ==============================================================================
# Ausfuehren:
#   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\azure-deploy.ps1
# ==============================================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# KONFIGURATION - hier anpassen
# ------------------------------------------------------------------------------
$RESOURCE_GROUP    = "elevator-monitoring-rg"
$LOCATION          = "westeurope"           # germanywestcentral unterstuetzt kein PostgreSQL (Student)
$REGISTRY_NAME     = "elevatormonitoring"   # NUR Kleinbuchstaben+Zahlen, global eindeutig
$POSTGRES_SERVER   = "elevator-db-hn"       # Kleinbuchstaben+Zahlen+Bindestrich, global eindeutig
$POSTGRES_ADMIN    = "pgadmin"
$POSTGRES_PASSWORD = "ElevatorHN2024!"
$DB_NAME           = "elevator_db"
$CONTAINER_ENV     = "elevator-cae"
$POLLER_IMAGE      = "elevator-poller"
$GRAFANA_IMAGE     = "elevator-grafana"

# JWT-Token aus .env lesen (PS 5.1 kompatibel, kein ?. Operator)
$JWT_TOKEN = ""
if (Test-Path ".env") {
    $envLines = Get-Content ".env"
    foreach ($line in $envLines) {
        if ($line -match "^ELEVISION_JWT_TOKEN=(.+)$") {
            $JWT_TOKEN = $Matches[1]
            break
        }
    }
}
if (-not $JWT_TOKEN) {
    Write-Warning "ELEVISION_JWT_TOKEN nicht in .env gefunden."
    $JWT_TOKEN = Read-Host "Bitte JWT-Token eingeben (oder Enter fuer leer)"
}

# ------------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ------------------------------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Cyan
}
function Write-OK($msg) {
    Write-Host "    OK  $msg" -ForegroundColor Green
}
function Write-Info($msg) {
    Write-Host "    ... $msg" -ForegroundColor Gray
}

# ------------------------------------------------------------------------------
# 0. VORAUSSETZUNGEN PRUEFEN
# ------------------------------------------------------------------------------
Write-Step "Voraussetzungen pruefen"

$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Error "Azure CLI nicht gefunden. Installieren: https://aka.ms/installazurecliwindows"
    exit 1
}
Write-OK "Azure CLI gefunden"

$accountJson = az account show -o json 2>$null
if (-not $accountJson) {
    Write-Host "Nicht eingeloggt. Starte az login..." -ForegroundColor Yellow
    az login
    $accountJson = az account show -o json
}
$account = $accountJson | ConvertFrom-Json
Write-OK "Eingeloggt als: $($account.name)"

Write-Info "Container Apps Extension pruefen..."
az extension add --name containerapp --upgrade --only-show-errors 2>$null
Write-OK "Container Apps Extension bereit"

# ------------------------------------------------------------------------------
# 1. RESOURCE PROVIDER REGISTRIEREN (einmalig pro Subscription)
# ------------------------------------------------------------------------------
Write-Step "Azure Resource Provider registrieren"
$providers = @(
    "Microsoft.ContainerRegistry",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.App",
    "Microsoft.OperationalInsights"
)
foreach ($p in $providers) {
    $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
    if ($state -eq "Registered") {
        Write-OK "$p (bereits registriert)"
    } else {
        Write-Info "$p wird registriert..."
        az provider register --namespace $p --output none
    }
}
Write-Info "Warte bis alle Provider bereit sind (max. 2 Minuten)..."
foreach ($p in $providers) {
    $waited = 0
    do {
        Start-Sleep -Seconds 5
        $waited += 5
        $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
    } while ($state -ne "Registered" -and $waited -lt 120)
    if ($state -eq "Registered") {
        Write-OK "$p registriert"
    } else {
        Write-Host "  WARNUNG: $p noch nicht registriert - Skript laeuft trotzdem weiter" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------------------
# 2. RESOURCE GROUP
# ------------------------------------------------------------------------------
Write-Step "Resource Group: $RESOURCE_GROUP"

# Warten falls die Gruppe noch geloescht wird (verhindert "ResourceGroupBeingDeleted")
$existingRg = az group show --name $RESOURCE_GROUP -o json 2>$null
if ($existingRg) {
    $rgState = ($existingRg | ConvertFrom-Json).properties.provisioningState
    if ($rgState -eq "Deleting") {
        Write-Host "  Resource Group wird noch geloescht - warte auf Abschluss..." -ForegroundColor Yellow
        $waited = 0
        do {
            Start-Sleep -Seconds 15
            $waited += 15
            $existingRg = az group show --name $RESOURCE_GROUP -o json 2>$null
            Write-Host "  ... $waited s gewartet" -ForegroundColor Gray
        } while ($existingRg -and $waited -lt 300)
        if ($existingRg) {
            Write-Error "Resource Group nach 5 Minuten noch nicht geloescht. Bitte manuell pruefen."
            exit 1
        }
        Write-OK "Loeschung abgeschlossen"
    } else {
        Write-OK "Resource Group existiert bereits (State: $rgState)"
    }
}

az group create --name $RESOURCE_GROUP --location $LOCATION --output none
Write-OK "Resource Group bereit in $LOCATION"

# ------------------------------------------------------------------------------
# 3. CONTAINER REGISTRY
# ------------------------------------------------------------------------------
Write-Step "Container Registry: $REGISTRY_NAME"

# Pruefe ob Name verfuegbar ist
$nameCheck = az acr check-name --name $REGISTRY_NAME -o json 2>$null | ConvertFrom-Json
if ($nameCheck -and -not $nameCheck.nameAvailable) {
    Write-Host "  WARNUNG: Registry-Name '$REGISTRY_NAME' ist nicht verfuegbar." -ForegroundColor Yellow
    Write-Host "  Grund: $($nameCheck.reason)" -ForegroundColor Yellow
    Write-Host "  Bitte $REGISTRY_NAME in der KONFIGURATION oben aendern (z.B. elevatormonitoring2)." -ForegroundColor Yellow
    $newName = Read-Host "  Neuen Registry-Namen eingeben"
    if ($newName) { $REGISTRY_NAME = $newName }
}

az acr create `
    --resource-group $RESOURCE_GROUP `
    --name $REGISTRY_NAME `
    --sku Basic `
    --admin-enabled true `
    --output none
$REGISTRY_SERVER = "$REGISTRY_NAME.azurecr.io"
Write-OK "Registry: $REGISTRY_SERVER"

# ------------------------------------------------------------------------------
# 3. DOCKER IMAGES BAUEN UND PUSHEN
# ------------------------------------------------------------------------------
Write-Step "Docker Images lokal bauen und nach Azure pushen"
# Hinweis: 'az acr build' (Cloud-Build) ist bei Azure for Students gesperrt.
# Wir bauen die Images lokal mit Docker und pushen sie dann in die Registry.

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Error "Docker nicht gefunden. Docker Desktop installieren und starten: https://www.docker.com/products/docker-desktop/"
    exit 1
}

Write-Info "Einloggen in Registry..."
az acr login --name $REGISTRY_NAME

Write-Info "Poller-Image lokal bauen (dauert 3-5 Minuten)..."
docker build -f Dockerfile -t "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" .
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Build fehlgeschlagen"; exit 1 }

Write-Info "Poller-Image hochladen..."
docker push "$REGISTRY_SERVER/${POLLER_IMAGE}:latest"
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Push fehlgeschlagen"; exit 1 }
Write-OK "Poller-Image gepusht: $REGISTRY_SERVER/${POLLER_IMAGE}:latest"

Write-Info "Grafana-Image lokal bauen..."
docker build -f Dockerfile.grafana -t "$REGISTRY_SERVER/${GRAFANA_IMAGE}:latest" .
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Build fehlgeschlagen"; exit 1 }

Write-Info "Grafana-Image hochladen..."
docker push "$REGISTRY_SERVER/${GRAFANA_IMAGE}:latest"
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Push fehlgeschlagen"; exit 1 }
Write-OK "Grafana-Image gepusht: $REGISTRY_SERVER/${GRAFANA_IMAGE}:latest"

# ------------------------------------------------------------------------------
# 4. POSTGRESQL FLEXIBLE SERVER
# ------------------------------------------------------------------------------
Write-Step "PostgreSQL Flexible Server: $POSTGRES_SERVER"

# try/catch noetig: az gibt Exit-Code != 0 wenn Server nicht existiert,
# was mit $ErrorActionPreference="Stop" einen Abbruch ausloest
$pgJson = $null
try {
    $pgJson = az postgres flexible-server show `
        --resource-group $RESOURCE_GROUP `
        --name $POSTGRES_SERVER `
        -o json 2>$null
} catch {
    $pgJson = $null
}
if (-not $pgJson) {
    Write-Info "Server wird erstellt (dauert 3-5 Minuten)..."
    az postgres flexible-server create `
        --resource-group $RESOURCE_GROUP `
        --name $POSTGRES_SERVER `
        --location $LOCATION `
        --admin-user $POSTGRES_ADMIN `
        --admin-password $POSTGRES_PASSWORD `
        --sku-name Standard_B1ms `
        --tier Burstable `
        --storage-size 32 `
        --version 16 `
        --public-access None `
        --output none
    Write-OK "Server erstellt"
} else {
    Write-OK "Server existiert bereits"
}

$POSTGRES_FQDN = az postgres flexible-server show `
    --resource-group $RESOURCE_GROUP `
    --name $POSTGRES_SERVER `
    --query "fullyQualifiedDomainName" -o tsv
Write-OK "FQDN: $POSTGRES_FQDN"

Write-Info "TimescaleDB Extension aktivieren..."
az postgres flexible-server parameter set `
    --resource-group $RESOURCE_GROUP `
    --server-name $POSTGRES_SERVER `
    --name azure.extensions `
    --value TIMESCALEDB `
    --output none
Write-OK "TimescaleDB Extension aktiviert"

Write-Info "Firewall fuer Azure-Dienste oeffnen..."
az postgres flexible-server firewall-rule create `
    --resource-group $RESOURCE_GROUP `
    --name $POSTGRES_SERVER `
    --rule-name AllowAllAzureServices `
    --start-ip-address 0.0.0.0 `
    --end-ip-address 0.0.0.0 `
    --output none
Write-OK "Azure-Firewall-Regel gesetzt"

$LOCAL_IP = (Invoke-RestMethod "https://api.ipify.org")
Write-Info "Eigene IP $LOCAL_IP temporaer erlauben..."
az postgres flexible-server firewall-rule create `
    --resource-group $RESOURCE_GROUP `
    --name $POSTGRES_SERVER `
    --rule-name LocalSetup `
    --start-ip-address $LOCAL_IP `
    --end-ip-address $LOCAL_IP `
    --output none
Write-OK "Temporaere Firewall-Regel gesetzt"

Write-Info "Datenbank $DB_NAME erstellen..."
try {
    az postgres flexible-server db create `
        --resource-group $RESOURCE_GROUP `
        --server-name $POSTGRES_SERVER `
        --database-name $DB_NAME `
        --output none 2>$null
} catch { <# DB existiert bereits - OK #> }
Write-OK "Datenbank erstellt"

# Schema einspielen (PS 5.1 kompatibel: kein ?. Operator)
Write-Step "Datenbank-Schema einspielen"
$psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
if ($psqlCmd) {
    $psqlPath = $psqlCmd.Source
    Write-Info "psql gefunden: $psqlPath"
    $env:PGPASSWORD = $POSTGRES_PASSWORD
    Write-Info "Fuehre schema.sql aus (ca. 30 Sekunden)..."
    Get-Content schema.sql | psql -h $POSTGRES_FQDN -U $POSTGRES_ADMIN -d $DB_NAME --set=sslmode=require
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Write-OK "Schema eingespielt"
} else {
    Write-Host ""
    Write-Host "  HINWEIS: psql nicht gefunden." -ForegroundColor Yellow
    Write-Host "  Bitte PostgreSQL-Client installieren:" -ForegroundColor Yellow
    Write-Host "  https://www.postgresql.org/download/windows/" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Dann diese zwei Befehle ausfuehren:" -ForegroundColor Yellow
    Write-Host "  1)  " -NoNewline -ForegroundColor White
    Write-Host "`$env:PGPASSWORD='$POSTGRES_PASSWORD'" -ForegroundColor Yellow
    Write-Host "  2)  " -NoNewline -ForegroundColor White
    Write-Host "  psql -h $POSTGRES_FQDN -U $POSTGRES_ADMIN -d $DB_NAME --set=sslmode=require -f schema.sql" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Enter druecken wenn Schema eingespielt wurde (Strg+C zum Abbrechen)"
}

Write-Info "Temporaere Firewall-Regel entfernen..."
try {
    az postgres flexible-server firewall-rule delete `
        --resource-group $RESOURCE_GROUP `
        --name $POSTGRES_SERVER `
        --rule-name LocalSetup `
        --yes `
        --output none 2>$null
} catch { <# Regel existiert nicht mehr - OK #> }
Write-OK "Temporaere Regel entfernt"

# ------------------------------------------------------------------------------
# 5. CONTAINER APPS ENVIRONMENT
# ------------------------------------------------------------------------------
Write-Step "Container Apps Environment: $CONTAINER_ENV"
az containerapp env create `
    --name $CONTAINER_ENV `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION `
    --output none
Write-OK "Environment erstellt"

$REGISTRY_USER = az acr credential show --name $REGISTRY_NAME --query "username" -o tsv
$REGISTRY_PASS = az acr credential show --name $REGISTRY_NAME --query "passwords[0].value" -o tsv

$DB_ENV_VARS = @(
    "DB_HOST=$POSTGRES_FQDN",
    "DB_PORT=5432",
    "DB_NAME=$DB_NAME",
    "DB_USER=$POSTGRES_ADMIN",
    "DB_SSLMODE=require",
    "ELEVISION_API_BASE=https://api.elevision.de/",
    "LOG_LEVEL=INFO"
)
$DB_SECRETS = @(
    "db-password=$POSTGRES_PASSWORD",
    "jwt-token=$JWT_TOKEN"
)
$DB_SECRET_REFS = @(
    "DB_PASSWORD=secretref:db-password",
    "ELEVISION_JWT_TOKEN=secretref:jwt-token"
)

# ------------------------------------------------------------------------------
# 6. GRAFANA CONTAINER APP
# ------------------------------------------------------------------------------
Write-Step "Grafana deployen"
az containerapp create `
    --name grafana `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${GRAFANA_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
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
        "GF_POSTGRES_SSLMODE=require" `
        "GF_POSTGRES_PASSWORD=secretref:gf-postgres-password" `
        "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/elevator_dashboard.json" `
    --output none
$GRAFANA_URL = az containerapp show `
    --name grafana `
    --resource-group $RESOURCE_GROUP `
    --query "properties.configuration.ingress.fqdn" -o tsv
Write-OK "Grafana: https://$GRAFANA_URL"

# ------------------------------------------------------------------------------
# 7. API-POLLER CONTAINER APP
# ------------------------------------------------------------------------------
Write-Step "API-Poller deployen (alle 60 s)"
az containerapp create `
    --name api-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
    --command "python" "api_poller.py" `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --ingress internal `
    --target-port 8080 `
    --secrets $DB_SECRETS `
    --env-vars ($DB_ENV_VARS + $DB_SECRET_REFS + @("METRICS_PORT=8080", "CB_FAILURE_THRESHOLD=5", "CB_RECOVERY_TIMEOUT_SEC=60")) `
    --output none
Write-OK "API-Poller laeuft"

# ------------------------------------------------------------------------------
# 8. EXTENDED POLLER CONTAINER APP
# ------------------------------------------------------------------------------
Write-Step "Extended Poller deployen (Fehler, Tueren, Statistiken)"
az containerapp create `
    --name extended-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
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
# 9. DWD-POLLER CONTAINER APP
# ------------------------------------------------------------------------------
Write-Step "DWD-Wetter-Poller deployen (stuendlich)"
az containerapp create `
    --name dwd-poller `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
    --command "/bin/sh" "-c" "python dwd_poller.py --loop" `
    --min-replicas 1 `
    --max-replicas 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --secrets ("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password", "DWD_STATION_ID=10729", "DWD_POLL_INTERVAL_SEC=3600")) `
    --output none
Write-OK "DWD-Poller laeuft"

# ------------------------------------------------------------------------------
# 10. ML-FORECAST JOB (taeglich 02:00 UTC = 04:00 MESZ)
# ------------------------------------------------------------------------------
Write-Step "ML-Forecast Job deployen"
az containerapp job create `
    --name forecast-job `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
    --trigger-type Schedule `
    --cron-expression "0 2 * * *" `
    --replica-timeout 1800 `
    --replica-retry-limit 1 `
    --replica-completion-count 1 `
    --parallelism 1 `
    --cpu 0.5 `
    --memory 1.0Gi `
    --command "python" "forecast_service.py" `
    --secrets ("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password", "FORECAST_HORIZON_DAYS=14", "FORECAST_HISTORY_DAYS=365")) `
    --output none
Write-OK "Forecast-Job registriert (taeglich 02:00 UTC)"

# ------------------------------------------------------------------------------
# 11. ANOMALIE-ALERTER JOB (taeglich 07:00 UTC = 09:00 MESZ)
# ------------------------------------------------------------------------------
Write-Step "Anomalie-Alerter Job deployen"
az containerapp job create `
    --name alerter-job `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV `
    --image "$REGISTRY_SERVER/${POLLER_IMAGE}:latest" `
    --registry-server $REGISTRY_SERVER `
    --registry-username $REGISTRY_USER `
    --registry-password $REGISTRY_PASS `
    --trigger-type Schedule `
    --cron-expression "0 7 * * *" `
    --replica-timeout 600 `
    --replica-retry-limit 1 `
    --replica-completion-count 1 `
    --parallelism 1 `
    --cpu 0.25 `
    --memory 0.5Gi `
    --command "/bin/sh" "-c" "python anomaly_alerter.py --days 1" `
    --secrets ("db-password=$POSTGRES_PASSWORD") `
    --env-vars ($DB_ENV_VARS + @("DB_PASSWORD=secretref:db-password", "ALERT_Z_CRITICAL=2.0", "ALERT_Z_WARNING=1.5")) `
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
Write-Host " Datenbank:" -ForegroundColor White
Write-Host "   Host: $POSTGRES_FQDN" -ForegroundColor Gray
Write-Host "   DB:   $DB_NAME  |  User: $POSTGRES_ADMIN" -ForegroundColor Gray
Write-Host ""
Write-Host " Laufende Container Apps:" -ForegroundColor White
Write-Host "   api-poller      (dauerhaft, alle 60 s)" -ForegroundColor Gray
Write-Host "   extended-poller (dauerhaft, 1 min - 1 h)" -ForegroundColor Gray
Write-Host "   dwd-poller      (dauerhaft, alle 60 min)" -ForegroundColor Gray
Write-Host "   grafana         (dauerhaft, oeffentlich erreichbar)" -ForegroundColor Gray
Write-Host ""
Write-Host " Geplante Jobs:" -ForegroundColor White
Write-Host "   forecast-job  (taeglich 02:00 UTC = 04:00 MESZ)" -ForegroundColor Gray
Write-Host "   alerter-job   (taeglich 07:00 UTC = 09:00 MESZ)" -ForegroundColor Gray
Write-Host ""
Write-Host " Logs live anzeigen:" -ForegroundColor White
Write-Host "   az containerapp logs show --name api-poller --resource-group $RESOURCE_GROUP --follow" -ForegroundColor Gray
Write-Host "   az containerapp logs show --name grafana --resource-group $RESOURCE_GROUP --follow" -ForegroundColor Gray
Write-Host ""
Write-Host " NAECHSTER SCHRITT - Erstimport (einmalig):" -ForegroundColor White
Write-Host "   Siehe Anleitung Schritt 3 fuer CSV- und DWD-Import" -ForegroundColor Gray
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan

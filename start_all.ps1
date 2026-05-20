# Elevator Monitoring - Tagesstart
# Startet alle Poller in separaten Fenstern.
# Ausfuehren: Rechtsklick -> "Mit PowerShell ausfuehren"
#             oder im Terminal: .\start_all.ps1

$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = "$Root\venv\Scripts\python.exe"

# 1. Docker pruefen
Write-Host "Pruefe Docker..." -ForegroundColor Cyan
$containers = docker ps --format "{{.Names}}" 2>$null
$dbOk       = $containers -match "timescaledb"
$grafanaOk  = $containers -match "grafana"

if ((-not $dbOk) -or (-not $grafanaOk)) {
    Write-Host "Docker-Container nicht aktiv - starte Stack..." -ForegroundColor Yellow
    Set-Location $Root
    docker compose up -d
    Write-Host "Warte auf TimescaleDB..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
} else {
    Write-Host "  OK  TimescaleDB + Grafana laufen bereits." -ForegroundColor Green
}

# 2. Aktuelle Wetterdaten nachholen
Write-Host "Lade aktuelle DWD-Wetterdaten..." -ForegroundColor Cyan
& $Python "$Root\services\dwd_history_importer.py" --range recent
Write-Host "  OK  DWD-Daten importiert." -ForegroundColor Green

# 3. Poller in separaten Fenstern starten
$pollers = @(
    @{ Title = "DWD Wetter-Poller";              Script = "services\dwd_poller.py --loop";               Color = "Blue"      },
    @{ Title = "Elevision API-Poller";            Script = "services\api_poller.py";                      Color = "Green"     },
    @{ Title = "Elevision Extended Poller";       Script = "services\elevision_extended_poller.py";        Color = "DarkGreen" },
    @{ Title = "ML-Forecast Service";             Script = "services\forecast_service.py --loop";          Color = "Magenta"   },
    @{ Title = "Anomalie-Alerter";               Script = "services\anomaly_alerter.py --loop";           Color = "Yellow"    }
)

foreach ($p in $pollers) {
    $cmd = "Set-Location '$Root'; & '$Python' " + $p.Script
    Start-Process powershell -ArgumentList "-NoExit", "-Command", $cmd -WindowStyle Normal
    Write-Host "  Gestartet: $($p.Title)" -ForegroundColor $p.Color
    Start-Sleep -Seconds 2
}

# 4. Zusammenfassung
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Alle Dienste gestartet!"                   -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Grafana: http://localhost:3000  (admin / Test123)" -ForegroundColor White
Write-Host ""
Write-Host " DWD Wetter-Poller          alle 60 min"    -ForegroundColor Blue
Write-Host " Elevision API-Poller        alle 60 s"      -ForegroundColor Green
Write-Host " Elevision Extended Poller   1 min / 5 min / 1 h" -ForegroundColor DarkGreen
Write-Host " ML-Forecast Service         taeglich 02:00" -ForegroundColor Magenta
Write-Host " Anomalie-Alerter           taeglich 07:00" -ForegroundColor Yellow
Write-Host ""
Write-Host " Beenden: Ctrl+C in jedem Fenster" -ForegroundColor Gray

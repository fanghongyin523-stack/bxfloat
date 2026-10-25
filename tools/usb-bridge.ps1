# BXFloat USB bridge (no SIM / no hotspot)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsPath = Join-Path $Root "BxUsbBridge.cs"

Write-Host ""
Write-Host "======== BXFloat USB Bridge ========" -ForegroundColor Cyan
Write-Host "1) Plug USB cable and Trust PC"
Write-Host "2) MediaMTX + OBS streaming"
Write-Host "3) Phone: select USB mode, open overlay"
Write-Host "4) Keep this window open"
Write-Host ""

try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:18888/stream/index.m3u8" -UseBasicParsing -TimeoutSec 3
    Write-Host ("MediaMTX HLS OK HTTP " + $r.StatusCode) -ForegroundColor Green
} catch {
    Write-Host "MediaMTX not ready. Start mediamtx + OBS first." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $CsPath)) {
    Write-Host ("Missing file: " + $CsPath) -ForegroundColor Red
    exit 1
}

$code = [System.IO.File]::ReadAllText($CsPath, [System.Text.Encoding]::UTF8)
try {
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
} catch {
    $msg = $_.Exception.Message
    if ($msg -notmatch "already exists") {
        Write-Host ("Compile failed: " + $msg) -ForegroundColor Red
        throw
    }
}

Write-Host "Bridge loaded. Running..." -ForegroundColor Green
[BxUsbBridge]::Run()

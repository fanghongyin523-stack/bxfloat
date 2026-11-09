# BXFloat USB bridge (no SIM / no hotspot)
# PC media port :18554 — any publisher (OBS / other) via MediaMTX or compatible RTSP source.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsPath = Join-Path $Root "BxUsbBridge.cs"

Write-Host ""
Write-Host "======== BXFloat USB Direct ========" -ForegroundColor Cyan
Write-Host "1) Plug USB cable and Trust PC"
Write-Host "2) Start PC media source on :18554 (MediaMTX + OBS/other, path=stream)"
Write-Host "3) Phone: USB mode + enable replace camera"
Write-Host "4) Keep this window open (acts as Direct Link)"
Write-Host "   Bridges: RTSP :18554 (replace) + HLS :18888"
Write-Host ""

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 18554)
    $tcp.Close()
    Write-Host "PC media RTSP :18554 reachable" -ForegroundColor Green
} catch {
    Write-Host "PC media RTSP :18554 not ready. Start MediaMTX (or other) + your publisher first." -ForegroundColor Yellow
}
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:18888/stream/index.m3u8" -UseBasicParsing -TimeoutSec 3
    Write-Host ("PC media HLS OK HTTP " + $r.StatusCode) -ForegroundColor Green
} catch {
    Write-Host "HLS optional (not required for replace)." -ForegroundColor DarkYellow
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

Write-Host "Direct link running..." -ForegroundColor Green
[BxUsbBridge]::Run()

# BXFloat USB 直连桥（无需手机卡 / 个人热点）
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsPath = Join-Path $Root "BxUsbBridge.cs"

Write-Host ""
Write-Host "======== BXFloat USB 直连助手（无卡方案）========" -ForegroundColor Cyan
Write-Host "不需要个人热点 / 手机卡。"
Write-Host "1) 数据线插上并点信任"
Write-Host "2) 电脑 MediaMTX+OBS 推流中"
Write-Host "3) 手机选 数据线 并打开悬浮窗"
Write-Host "4) 本窗口保持运行"
Write-Host ""

try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:18888/stream/index.m3u8" -UseBasicParsing -TimeoutSec 3
    Write-Host "MediaMTX HLS OK (HTTP $($r.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "MediaMTX 未通：请先开 Desktop\mediamtx 并让 OBS 推流" -ForegroundColor Yellow
}

if (-not (Test-Path $CsPath)) {
    Write-Host "缺少 BxUsbBridge.cs: $CsPath" -ForegroundColor Red
    exit 1
}

$code = Get-Content -LiteralPath $CsPath -Raw -Encoding UTF8
try {
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
} catch {
    # 类型已加载时忽略
    if ($_.Exception.Message -notmatch "already exists|已存在") {
        Write-Host "编译桥接失败: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Write-Host "桥接模块已加载，开始运行…" -ForegroundColor Green
[BxUsbBridge]::Run()

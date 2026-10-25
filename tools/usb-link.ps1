# BXFloat：数据线（USB 个人热点）助手
# 作用：查出电脑在「iPhone USB」网卡上的 IP，并探测 MediaMTX HLS 是否可访问

$ErrorActionPreference = "Continue"
$hlsPort = 18888
$streamPath = "stream"

Write-Host ""
Write-Host "======== BXFloat 数据线助手 ========" -ForegroundColor Cyan
Write-Host "步骤提醒："
Write-Host "  1. 手机：设置 → 个人热点 → 打开「允许其他人加入」"
Write-Host "  2. 用数据线插电脑，手机点「信任」"
Write-Host "  3. 电脑需已装 iTunes 或「Apple 设备」驱动"
Write-Host "  4. MediaMTX + OBS 照常推流（与局域网相同）"
Write-Host ""

$candidates = @()
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
    $ip = $_.IPAddress
    if ($ip -like "172.20.10.*" -or $ip -like "192.168.137.*" -or $ip -like "169.254.*") {
        $if = Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $alias = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name
        $candidates += [pscustomobject]@{
            IP        = $ip
            Adapter   = $alias
            Interface = $_.InterfaceAlias
        }
    }
}

# 也按网卡名猜 Apple / iPhone USB
Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq "Up" -and (
        $_.Name -match "iPhone|Apple|USB" -or
        $_.InterfaceDescription -match "iPhone|Apple|Mobile"
    )
} | ForEach-Object {
    $addrs = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($a in $addrs) {
        if ($candidates.IP -notcontains $a.IPAddress) {
            $candidates += [pscustomobject]@{
                IP        = $a.IPAddress
                Adapter   = $_.Name
                Interface = $_.InterfaceDescription
            }
        }
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "未检测到 USB 热点网卡。" -ForegroundColor Yellow
    Write-Host "请确认：个人热点已开 + 线已插 + 信任电脑 + 已装 Apple 驱动。"
    Write-Host "也可在「设置 → 网络和 Internet → 更改适配器选项」里看是否有 iPhone USB。"
    Write-Host ""
    Write-Host "手机端可先试填默认：172.20.10.2" -ForegroundColor Green
} else {
    Write-Host "检测到可能的 USB 电脑 IP：" -ForegroundColor Green
    $i = 1
    foreach ($c in $candidates) {
        Write-Host ("  [{0}] {1}  （网卡：{2}）" -f $i, $c.IP, $c.Adapter)
        $i++
    }
    $primary = $candidates[0].IP
    Write-Host ""
    Write-Host "请在手机 BXFloat「连接 → 数据线」填：" -ForegroundColor Cyan
    Write-Host "  $primary" -ForegroundColor White
    Write-Host "播放地址将是："
    Write-Host "  http://${primary}:${hlsPort}/${streamPath}/index.m3u8"
}

Write-Host ""
Write-Host "探测本机 HLS（127.0.0.1:$hlsPort）..."
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:${hlsPort}/${streamPath}/index.m3u8" -UseBasicParsing -TimeoutSec 3
    Write-Host "  MediaMTX HLS：OK（HTTP $($r.StatusCode)）" -ForegroundColor Green
} catch {
    Write-Host "  MediaMTX HLS：未通 — 请先开 Desktop\mediamtx 并让 OBS 推流" -ForegroundColor Yellow
}

if ($candidates.Count -gt 0) {
    $probeIP = $candidates[0].IP
    Write-Host "探测 USB 网卡 HLS（${probeIP}:${hlsPort}）..."
    try {
        $r2 = Invoke-WebRequest -Uri "http://${probeIP}:${hlsPort}/${streamPath}/index.m3u8" -UseBasicParsing -TimeoutSec 3
        Write-Host "  USB 地址 HLS：OK（HTTP $($r2.StatusCode)）" -ForegroundColor Green
    } catch {
        Write-Host "  USB 地址 HLS：失败 — 检查防火墙是否放行 TCP $hlsPort" -ForegroundColor Yellow
        Write-Host "  可管理员运行：netsh advfirewall firewall add rule name=`"MediaMTX HLS $hlsPort`" dir=in action=allow protocol=TCP localport=$hlsPort"
    }
}

Write-Host ""
Write-Host "======== 结束 ========" -ForegroundColor Cyan

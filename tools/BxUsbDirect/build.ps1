$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc not found: $csc" }

$outDir = Join-Path $here 'bin'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item (Join-Path $here 'ports.ini') $outDir -Force
Copy-Item (Join-Path $here 'vcu1-types.ini') $outDir -Force
# Real A/V samples for Demo (annex-B H.264 + ADTS AAC); regenerate with ffmpeg if missing.
$msDir = Join-Path (Split-Path $here) 'BxMediaSource'
foreach ($sample in @('demo-sample.annexb.h264', 'demo-sample.adts.aac')) {
  $src = Join-Path $msDir $sample
  $dst = Join-Path $outDir $sample
  if (Test-Path $src) { Copy-Item $src $dst -Force }
  elseif (Test-Path $dst) { /* keep existing bin copy */ }
  else { Write-Warning "sample missing: $sample (Demo needs it next to BxMediaSourceDemo.exe)" }
}

function Invoke-Csc([string]$outExe, [string[]]$sources) {
  $quotedSources = ($sources | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $argLine = '/nologo /optimize+ /out:"' + $outExe + '" ' + $quotedSources
  cmd /c "`"$csc`" $argLine"
  if ($LASTEXITCODE -ne 0) { throw "csc failed for $outExe" }
}

$relayOut = Join-Path $outDir 'BxUsbDirectRelay.exe'
Invoke-Csc $relayOut @(
  (Join-Path $here 'Vcu1Codec.cs'),
  (Join-Path $here 'BxmsCodec.cs'),
  (Join-Path $here 'TypeMap.cs'),
  (Join-Path $here 'Usbmux.cs'),
  (Join-Path $here 'SelfTest.cs'),
  (Join-Path $here 'BxUsbDirectRelay.cs')
)

$ms = Join-Path (Split-Path $here) 'BxMediaSource'
$clientOut = Join-Path $outDir 'BxMediaSourceDemo.exe'
Invoke-Csc $clientOut @(
  (Join-Path $here 'Vcu1Codec.cs'),
  (Join-Path $here 'BxmsCodec.cs'),
  (Join-Path $ms 'BxMediaSourceClient.cs'),
  (Join-Path $ms 'ProgramDemo.cs')
)

Write-Output "Built:"
Get-ChildItem $outDir | Format-Table Name, Length
Write-Output "Running selftest..."
& $relayOut selftest
if ($LASTEXITCODE -ne 0) { throw "selftest failed" }

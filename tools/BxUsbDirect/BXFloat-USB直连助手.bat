@echo off
title BXFloat USB Direct Relay (VCU1)
cd /d "%~dp0"
if not exist "%~dp0bin\BxUsbDirectRelay.exe" (
  echo Building...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" || goto :fail
)
echo.
echo USB direct channel: VCU1 via usbmux
echo LAN channel: start BXFloat-USB助手.bat separately for RTSP bridge
echo BXMS ingest default 127.0.0.1:18765
echo.
"%~dp0bin\BxUsbDirectRelay.exe"
echo.
pause
goto :eof
:fail
echo Build failed.
pause

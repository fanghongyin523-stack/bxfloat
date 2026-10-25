@echo off
title BXFloat USB Bridge
cd /d "%~dp0"
echo.
echo Starting USB bridge...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usb-bridge.ps1"
echo.
echo Bridge exited. If you saw red errors, send a screenshot.
pause

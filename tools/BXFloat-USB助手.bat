@echo off
chcp 65001 >nul
title BXFloat USB 助手
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usb-link.ps1"
echo.
pause

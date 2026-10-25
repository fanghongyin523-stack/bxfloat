@echo off
chcp 65001 >nul
title BXFloat USB 直连助手（无需手机卡）
cd /d "%~dp0"
echo.
echo 正在启动 USB 直连桥（无需个人热点）...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usb-bridge.ps1"
echo.
pause

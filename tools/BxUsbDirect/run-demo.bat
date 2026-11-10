@echo off
chcp 65001 >nul
title BxMediaSource Demo（循环+自动重连）
cd /d "%~dp0"
echo.
echo 推荐直接用「一键推Demo.bat」（会自动开助手）。
echo 本窗口：循环推 H.264+AAC 到 127.0.0.1:18765；断线自动重连。
echo.
"%~dp0bin\BxMediaSourceDemo.exe" %*
echo.
pause

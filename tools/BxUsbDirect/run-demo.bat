@echo off
chcp 65001 >nul
title BxMediaSource Demo
cd /d "%~dp0"
echo.
echo Keep BXFloat-USB Direct Relay running first.
echo Demo sends real H.264+AAC samples to 127.0.0.1:18765 then exits.
echo.
"%~dp0bin\BxMediaSourceDemo.exe" %*
echo.
echo ---- demo send OK = success ----
echo ---- demo failed = relay not listening on 18765 ----
pause

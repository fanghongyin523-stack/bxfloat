@echo off
chcp 65001 >nul
title BxMediaSource Demo (loop)
cd /d "%~dp0"
echo.
echo Keep BXFloat-USB Direct Relay running first.
echo Demo loops real H.264+AAC to 127.0.0.1:18765 until you close this window / Ctrl+C.
echo Optional: run-demo.bat --seconds 60
echo.
"%~dp0bin\BxMediaSourceDemo.exe" %*
echo.
echo ---- demo send OK / loop ended = success ----
echo ---- demo failed = relay not listening on 18765 ----
pause

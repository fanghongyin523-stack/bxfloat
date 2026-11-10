@echo off
chcp 65001 >nul
title BxMediaSource Demo
cd /d "%~dp0"
call "%~dp0run-demo.bat" %*

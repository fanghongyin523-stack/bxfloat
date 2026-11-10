@echo off
chcp 65001 >nul
title BXFloat USB Direct Relay (VCU1)
cd /d "%~dp0"

if not exist "%~dp0bin\BxUsbDirectRelay.exe" (
  echo 正在编译...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" || goto :fail
)

REM 若有热编译产物，启动前替换（旧进程占用时写到了 .new.exe）
if exist "%~dp0bin\BxUsbDirectRelay.new.exe" (
  echo 发现新版助手，正在替换...
  copy /y "%~dp0bin\BxUsbDirectRelay.new.exe" "%~dp0bin\BxUsbDirectRelay.exe" >nul
  del "%~dp0bin\BxUsbDirectRelay.new.exe" >nul 2>nul
)

echo.
echo ========== USB 直连助手（保持本窗口开着）==========
echo  手机注 dylib + 替换开后，再用「一键推Demo.bat」
echo  手机暂时没连上时只会丢帧，不会把 Demo 踢掉
echo =================================================
echo.
"%~dp0bin\BxUsbDirectRelay.exe"
echo.
pause
goto :eof
:fail
echo 编译失败
pause

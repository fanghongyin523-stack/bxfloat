@echo off
chcp 65001 >nul
title 一键推Demo（自动开助手+循环推流）
cd /d "%~dp0"

if not exist "%~dp0bin\BxUsbDirectRelay.exe" (
  echo 正在编译助手...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" || goto :fail
)
if not exist "%~dp0bin\BxMediaSourceDemo.exe" (
  echo 正在编译 Demo...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" || goto :fail
)

echo.
echo ========== 用法（就这三步）==========
echo  1. 手机：注好 dylib，抖音打开，面板「替换」开、「推流声音」开
echo  2. 本脚本：会自动开助手（若未开）并开始推 Demo
echo  3. 两个黑窗口都不要关；手机面板应看到 VCU1已连 / ok、aud 上涨
echo =====================================
echo.

REM 18765 已在听 → 助手已开；否则新开一个助手窗口
powershell -NoProfile -Command "try { $c=New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',18765); $c.Close(); exit 0 } catch { exit 1 }"
if errorlevel 1 (
  echo [一键] 助手未开 → 正在启动 USB直连助手...
  start "BXFloat USB Direct Relay" "%~dp0BXFloat-USB直连助手.bat"
  echo [一键] 等待助手监听 18765...
  set /a _n=0
  :wait_ingest
  set /a _n+=1
  if %_n% GEQ 30 (
    echo [一键] 等不到助手，请手动双击 BXFloat-USB直连助手.bat 后再开本脚本
    pause
    exit /b 1
  )
  ping -n 2 127.0.0.1 >nul
  powershell -NoProfile -Command "try { $c=New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',18765); $c.Close(); exit 0 } catch { exit 1 }"
  if errorlevel 1 goto wait_ingest
  echo [一键] 助手已就绪
) else (
  echo [一键] 助手已在跑（18765）
)

echo [一键] 开始循环推 Demo（断线会自动重连，Ctrl+C 结束）
echo.
if exist "%~dp0bin\BxMediaSourceDemo.new.exe" (
  copy /y "%~dp0bin\BxMediaSourceDemo.new.exe" "%~dp0bin\BxMediaSourceDemo.exe" >nul 2>nul
)
"%~dp0bin\BxMediaSourceDemo.exe" %*
echo.
pause
goto :eof
:fail
echo 编译失败
pause

@echo off
title Radeon-atieclxx-SSD-Fix - Status
if not exist "%~dp0Script\check.ps1" (
  echo Please extract the ZIP archive completely first and then run CHECK.cmd.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Script\check.ps1"
echo.
pause

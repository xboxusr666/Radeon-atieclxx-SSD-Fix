@echo off
title Radeon-atieclxx-SSD-Fix - Remove
if not exist "%~dp0Script\remove.ps1" (
  echo Please extract the ZIP archive completely first and then run REMOVE.cmd.
  pause
  exit /b 1
)
fltmc >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Script\remove.ps1"
echo.
pause

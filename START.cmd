@echo off
title Radeon-atieclxx-SSD-Fix
if not exist "%~dp0Script\Gui.ps1" (
  echo Please extract the ZIP archive completely first and then run START.cmd.
  pause
  exit /b 1
)
fltmc >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Script\Gui.ps1"
exit /b

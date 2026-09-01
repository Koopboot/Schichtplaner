@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Schichtplaner.ps1"
if errorlevel 1 (
  echo.
  echo Der Schichtplaner konnte nicht gestartet werden.
  echo Falls eure Firmenrichtlinie PowerShell-Skripte blockiert, muss die IT die Ausfuehrung erlauben.
  pause
)

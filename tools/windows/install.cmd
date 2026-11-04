@echo off
rem Double-click to install contextGIST for the current user (no admin needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause

@echo off
rem Removes contextGIST for the current user.
rem Runs from a copy in %TEMP% so the install folder can be deleted. Everything
rem is on one line so cmd never re-reads this file after it has been deleted.
copy /y "%~dp0uninstall.ps1" "%TEMP%\contextgist-uninstall.ps1" >nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\contextgist-uninstall.ps1" & del "%TEMP%\contextgist-uninstall.ps1" >nul 2>&1 & exit /b

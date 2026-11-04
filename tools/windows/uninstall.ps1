<#
.SYNOPSIS
  Removes everything install.ps1 created. Safe to run twice.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\contextGIST'),
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\contextGIST'
)
$ErrorActionPreference = 'Stop'

$running = Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw 'contextGIST is running. Close it and run the uninstaller again.' }

# Leave the folder we are about to delete so it is not our working directory.
Set-Location $env:TEMP
Remove-Item (Join-Path $StartMenuDir 'contextGIST.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) {
    try { Remove-Item $InstallDir -Recurse -Force }
    catch {
        # uninstall.cmd may still hold itself open; finish after this process exits.
        Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', "ping -n 3 127.0.0.1 >nul & rmdir /s /q `"$InstallDir`""
    }
}
Write-Host 'contextGIST removed.'

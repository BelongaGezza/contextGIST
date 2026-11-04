<#
.SYNOPSIS
  Removes everything install.ps1 created. Safe to run twice.

.DESCRIPTION
  The install folder is read from the Apps & Features entry (InstallLocation),
  falling back to the default, unless -InstallDir is given. It is only deleted
  if it really is a contextGIST install (contains app.json naming contextGIST),
  so a wrong path can never delete an unrelated folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\contextGIST'
)
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('InstallDir')) {
    $recorded = (Get-ItemProperty $UninstallKey -ErrorAction SilentlyContinue).InstallLocation
    $InstallDir = if ($recorded) { $recorded } else { Join-Path $env:LOCALAPPDATA 'Programs\contextGIST' }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

$isOurs = $false
$marker = Join-Path $InstallDir 'app.json'
if (Test-Path $marker) {
    try { $isOurs = ((Get-Content $marker -Raw | ConvertFrom-Json).name -eq 'contextGIST') } catch { $isOurs = $false }
}
if ((Test-Path $InstallDir) -and -not $isOurs) {
    throw "$InstallDir does not look like a contextGIST install (no valid app.json). Nothing was deleted."
}

$prefix = $InstallDir + '\'
$running = Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw 'contextGIST is running. Close it and run the uninstaller again.' }

# Leave the folder we are about to delete so it is not our working directory.
Set-Location $env:TEMP
Remove-Item (Join-Path $StartMenuDir 'contextGIST.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) {
    # uninstall.cmd may be the batch file that launched us; cmd.exe keeps reading
    # a running batch file, so deleting it mid-run prints errors. Remove everything
    # else now and let a detached cmd delete the (then empty) folder after we exit.
    Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -ne "uninstall.cmd" } | Remove-Item -Recurse -Force
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c", "ping -n 3 127.0.0.1 >nul & if exist `"$InstallDir`" rmdir /s /q `"$InstallDir`""
}
Write-Host 'contextGIST removed.'

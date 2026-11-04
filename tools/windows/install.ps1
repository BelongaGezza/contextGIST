<#
.SYNOPSIS
  Per-user install of contextGIST. No administrator rights needed.

.DESCRIPTION
  Copies the app to %LOCALAPPDATA%\Programs\contextGIST, adds a Start menu
  shortcut and an "Apps & Features" entry (HKCU) so Windows can uninstall it.
  Writes nothing else: no services, scheduled tasks, startup entries or
  machine-wide registry keys. uninstall.ps1 removes exactly these things.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\contextGIST'),
    # Overridable so tests never touch the real Start menu / registry.
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\contextGIST',
    [switch]$NoShortcut,
    [switch]$NoRegistry
)
$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$app = Get-Content (Join-Path $src 'app.json') -Raw | ConvertFrom-Json
if (-not (Test-Path (Join-Path $src "bin\$($app.exe)"))) { throw "bin\$($app.exe) is missing from the package." }

# Refuse to overwrite a running copy rather than fail halfway.
$running = Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw "contextGIST is running. Close it and run the installer again." }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item (Join-Path $src 'bin') $InstallDir -Recurse -Force
foreach ($f in 'app.json', 'uninstall.ps1', 'uninstall.cmd', 'THIRD-PARTY.md') {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p $InstallDir -Force }
}

$exePath = Join-Path $InstallDir "bin\$($app.exe)"
if (-not $NoShortcut) {
    $lnk = Join-Path $StartMenuDir 'contextGIST.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $exePath
    $s.WorkingDirectory = Split-Path $exePath
    $s.Save()
}
if (-not $NoRegistry) {
    New-Item -Path $UninstallKey -Force | Out-Null
    $kb = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB)
    $vals = @{
        DisplayName     = 'contextGIST'
        DisplayVersion  = $app.version
        Publisher       = 'contextGIST'
        InstallLocation = $InstallDir
        UninstallString = "`"$env:SystemRoot\System32\cmd.exe`" /c `"$(Join-Path $InstallDir 'uninstall.cmd')`""
    }
    foreach ($k in $vals.Keys) { New-ItemProperty -Path $UninstallKey -Name $k -Value $vals[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $UninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $UninstallKey -Name EstimatedSize -Value $kb -PropertyType DWord -Force | Out-Null
}
Write-Host "Installed contextGIST $($app.version) to $InstallDir"
Write-Host 'To remove it: Settings > Apps > Installed apps > contextGIST > Uninstall.'

<#
.SYNOPSIS
  Per-user install of contextGIST. No administrator rights needed.

.DESCRIPTION
  Copies the app to %LOCALAPPDATA%\Programs\contextGIST, adds a Start menu
  shortcut and an "Apps & Features" entry (HKCU) so Windows can uninstall it.
  Writes nothing else: no services, scheduled tasks, startup entries or
  machine-wide registry keys. uninstall.ps1 removes exactly these things.
  Re-running upgrades in place and removes files left by an older version.
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

# Normalise, and refuse anything that is not a plain folder path: a drive root
# or a relative path would make the later copy and uninstall dangerous.
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($InstallDir -eq [System.IO.Path]::GetPathRoot($InstallDir).TrimEnd('\')) { throw "Refusing to install into a drive root: $InstallDir" }

# Never write into a folder that holds someone else's files.
if ((Test-Path $InstallDir) -and (Get-ChildItem $InstallDir -Force | Select-Object -First 1) -and -not (Test-Path (Join-Path $InstallDir 'app.json'))) {
    throw "$InstallDir exists and is not a contextGIST install. Choose an empty folder."
}

# Refuse to overwrite a running copy rather than fail halfway. Exact folder
# match (trailing separator), so a sibling like contextGIST2 is not confused.
$prefix = $InstallDir + '\'
$running = Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw "contextGIST is running. Close it and run the installer again." }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
# Replace bin\ wholesale so files removed in a newer version don't linger.
$binDest = Join-Path $InstallDir 'bin'
if (Test-Path $binDest) { Remove-Item $binDest -Recurse -Force }
Copy-Item (Join-Path $src 'bin') $InstallDir -Recurse -Force
foreach ($f in 'app.json', 'uninstall.ps1', 'uninstall.cmd', 'THIRD-PARTY.md') {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-Item $p $InstallDir -Force }
    elseif (Test-Path (Join-Path $InstallDir $f)) { Remove-Item (Join-Path $InstallDir $f) -Force }
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
        # uninstall.ps1 reads this back, so a custom -InstallDir is removed correctly.
        InstallLocation = $InstallDir
        UninstallString = "`"$env:SystemRoot\System32\cmd.exe`" /c `"$(Join-Path $InstallDir 'uninstall.cmd')`""
    }
    foreach ($k in $vals.Keys) { New-ItemProperty -Path $UninstallKey -Name $k -Value $vals[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $UninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $UninstallKey -Name EstimatedSize -Value $kb -PropertyType DWord -Force | Out-Null
}
Write-Host "Installed contextGIST $($app.version) to $InstallDir"
Write-Host 'To remove it: Settings > Apps > Installed apps > contextGIST > Uninstall.'

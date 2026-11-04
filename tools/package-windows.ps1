<#
.SYNOPSIS
  PROTOTYPE: package a Windows x64 build into dist/windows/ as a zip with a
  per-user installer and uninstaller (docs/WINDOWS_PLAN.md section 6).

.DESCRIPTION
  There is no contextGIST Windows app yet, so by default the payload is the
  throwaway capture-prober spike (apps/windows/spikes/capture-prober). This
  exercises the packaging, install and uninstall mechanics end to end. Pass
  -PayloadDir to package a real build later; nothing else needs to change.

  Output (gitignored; installers go to GitHub Releases, not the repo):
    dist/windows/contextGIST-<version>-x64.zip
    dist/windows/SHA256SUMS
  The zip is UNSIGNED. Signing (Authenticode) is a separate step, once a
  certificate route is chosen (WINDOWS_PLAN section 6 / docs/INSTALL_TODO.md).

.PARAMETER Version
  Version string used in the file name and the Apps & Features entry.
.PARAMETER PayloadDir
  Directory containing the built app. Must hold the exe named by -ExeName.
  Default: build and use the capture-prober spike.
.PARAMETER ExeName
  Main executable inside the payload. Default: capture-prober.exe.
.PARAMETER Target
  Rust target triple for the default payload. Default: x86_64-pc-windows-msvc.

.EXAMPLE
  pwsh tools/package-windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '0.0.0-prototype',
    [string]$PayloadDir,
    [string]$ExeName = 'capture-prober.exe',
    [string]$Target = 'x86_64-pc-windows-msvc'
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Out      = Join-Path $RepoRoot 'dist/windows'
$Template = Join-Path $PSScriptRoot 'windows'
$Name     = "contextGIST-$Version-x64"
$Stage    = Join-Path $Out "staging/$Name"

if (-not $PayloadDir) {
    $spike = Join-Path $RepoRoot 'apps/windows/spikes/capture-prober'
    # Windows targets are installed here, not in rust-toolchain.toml (W9).
    rustup target add $Target
    if ($LASTEXITCODE) { throw 'rustup target add failed' }
    cargo build --release --locked --manifest-path (Join-Path $spike 'Cargo.toml') --target $Target
    if ($LASTEXITCODE) { throw 'cargo build failed' }
    $PayloadDir = Join-Path $spike "target/$Target/release"
}
$exe = Join-Path $PayloadDir $ExeName
if (-not (Test-Path $exe)) { throw "Payload exe not found: $exe" }

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Stage 'bin') -Force | Out-Null
Copy-Item $exe (Join-Path $Stage 'bin')

# Metadata the installer reads, so it never hardcodes the payload.
[ordered]@{ name = 'contextGIST'; version = $Version; exe = $ExeName } |
    ConvertTo-Json | Set-Content (Join-Path $Stage 'app.json') -Encoding utf8

foreach ($f in 'install.ps1', 'uninstall.ps1', 'install.cmd', 'uninstall.cmd', 'INSTALL.txt') {
    Copy-Item (Join-Path $Template $f) $Stage
}
$tp = Join-Path $RepoRoot 'docs/THIRD-PARTY.md'
if (Test-Path $tp) { Copy-Item $tp (Join-Path $Stage 'THIRD-PARTY.md') }

$zip = Join-Path $Out "$Name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $zip
# Same layout as the macOS SHA256SUMS: "<hash>  <file>", lower-case hash.
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText((Join-Path $Out 'SHA256SUMS'), "$hash  $Name.zip`n")
Copy-Item (Join-Path $Template 'INSTALL.txt') (Join-Path $Out 'INSTALL.txt')

Write-Host "OK: $zip"
Write-Host "    sha256 $hash"
Write-Host '    UNSIGNED: Windows SmartScreen will warn on a downloaded copy (see INSTALL.txt).'

<#
.SYNOPSIS
  PROTOTYPE: build an MSIX from the same payload as tools/package-windows.ps1,
  optionally sign it. For the MSIX-vs-winget-vs-zip comparison in
  docs/WINDOWS_INSTALL_OPTIONS.md. Output (gitignored): dist/windows/*.msix

.PARAMETER PfxPath / PfxPassword
  Sign with this certificate. Its Subject MUST equal -Publisher. Without
  them the package is left unsigned, which Windows will not install normally.
.PARAMETER SelfSignedTest
  Create a throwaway self-signed cert in CurrentUser\My, sign with it, verify,
  and delete it. Proves the signing path works; the result is only
  installable on a machine that trusts that cert (admin: Trusted People).
#>
[CmdletBinding()]
param(
    [string]$Version = '0.0.1.0',            # MSIX versions are a.b.c.d
    [string]$PayloadDir,
    [string]$ExeName = 'capture-prober.exe',
    [string]$Publisher = 'CN=contextGIST Dev',
    [string]$PfxPath,
    [securestring]$PfxPassword,
    [switch]$SelfSignedTest,
    [string]$Target = 'x86_64-pc-windows-msvc'
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $RepoRoot 'dist/windows'
$Stage = Join-Path $Out 'staging/msix'

function Find-SdkTool([string]$n) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $hit = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$n" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1
    if (-not $hit) { throw "$n not found. Install the Windows SDK or use a VS Developer prompt." }
    $hit.FullName
}
$makeappx = Find-SdkTool 'makeappx.exe'

if (-not $PayloadDir) {
    $spike = Join-Path $RepoRoot 'apps/windows/spikes/capture-prober'
    rustup target add $Target; if ($LASTEXITCODE) { throw 'rustup failed' }
    cargo build --release --locked --manifest-path (Join-Path $spike 'Cargo.toml') --target $Target
    if ($LASTEXITCODE) { throw 'cargo build failed' }
    $PayloadDir = Join-Path $spike "target/$Target/release"
}
if (-not (Test-Path (Join-Path $PayloadDir $ExeName))) { throw "Payload exe not found in $PayloadDir" }

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory (Join-Path $Stage 'bin'), (Join-Path $Stage 'Assets') -Force | Out-Null
Copy-Item (Join-Path $PayloadDir $ExeName) (Join-Path $Stage 'bin')

# Placeholder logos (solid tile). Replace with real artwork before any release.
Add-Type -AssemblyName System.Drawing
foreach ($l in @{ 'StoreLogo' = 50; 'Square44x44Logo' = 44; 'Square150x150Logo' = 150 }.GetEnumerator()) {
    $bmp = New-Object System.Drawing.Bitmap $l.Value, $l.Value
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(31, 31, 31)); $g.Dispose()
    $bmp.Save((Join-Path $Stage "Assets/$($l.Key).png"), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

$m = Get-Content (Join-Path $PSScriptRoot 'windows/msix/AppxManifest.xml.in') -Raw
$m = $m.Replace('@NAME@', 'contextGIST').Replace('@PUBLISHER@', $Publisher).Replace('@VERSION@', $Version).Replace('@EXE@', $ExeName)
Set-Content (Join-Path $Stage 'AppxManifest.xml') $m -Encoding utf8

$msix = Join-Path $Out "contextGIST-$Version-x64.msix"
if (Test-Path $msix) { Remove-Item $msix -Force }
& $makeappx pack /d $Stage /p $msix /o
if ($LASTEXITCODE) { throw 'makeappx pack failed' }

$cert = $null
try {
    if ($SelfSignedTest) {
        $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature `
            -FriendlyName 'contextGIST test (delete me)' -CertStoreLocation 'Cert:\CurrentUser\My' `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
        $pfx = Join-Path $env:TEMP 'contextgist-test.pfx'
        $pw = ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
        $PfxPath = $pfx; $PfxPassword = $pw
    }
    if ($PfxPath) {
        $signtool = Find-SdkTool 'signtool.exe'
        $plain = [System.Net.NetworkCredential]::new('', $PfxPassword).Password
        & $signtool sign /fd SHA256 /f $PfxPath /p $plain $msix
        if ($LASTEXITCODE) { throw 'signtool sign failed' }
        Write-Host "Signed (subject $Publisher)."
    } else {
        Write-Host 'UNSIGNED: Windows will not install this normally (see docs/WINDOWS_INSTALL_OPTIONS.md).'
    }
} finally {
    if ($cert) { Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue }
    if ($SelfSignedTest -and $PfxPath) { Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue }
}
$hash = (Get-FileHash $msix -Algorithm SHA256).Hash.ToLower()
Write-Host "OK: $msix`n    sha256 $hash"

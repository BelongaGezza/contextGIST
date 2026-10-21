<#
.SYNOPSIS
  Drives the capture prober against a set of apps on a dev machine and appends
  one CSV row per trial (metadata only; never the selected text).

.DESCRIPTION
  Opens its own sample windows, sends Ctrl+A (SendKeys), and runs the prober
  with --expect-exe so a trial that lands in the wrong window is recorded as
  `wrong_target` instead of a result. It takes over keyboard focus for the
  duration: do not type while it runs.

  Safety: every window it creates has a title starting with "cgprobe-" and it
  closes only windows whose title matches that anchored prefix. Browsers run
  with a throwaway --user-data-dir, never your real profile. If a window cannot
  be activated the trial is skipped and no keys are sent.

  Not covered here (run by hand and add rows with --label): an elevated app,
  Firefox, Acrobat / Edge PDF, Slack/Teams, conhost.

.EXAMPLE
  pwsh -File run-app-matrix.ps1 -Prober ..\target\debug\capture-prober.exe -OutDir results -Trials 5
#>
param(
  [Parameter(Mandatory)][string]$Prober,
  [Parameter(Mandatory)][string]$OutDir,
  [int]$Trials = 5,
  [string[]]$Apps = @('notepad', 'notepad-overcap', 'winforms', 'edge', 'edge-overcap', 'edge-password', 'chrome', 'vscode', 'word', 'terminal')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Csv = Join-Path $OutDir 'results.csv'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("cgprobe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null

# Multi-line (CRLF), CJK, RTL and emoji, so offsets and the UTF-8 cap are exercised.
$line = "The quick brown fox jumps over the lazy dog. 中文字符测试 مرحبا بالعالم 👍🏽 🇬🇧"
$sample = (1..60 | ForEach-Object { "$line (line $_)" }) -join "`r`n"
$big = ("lorem ipsum dolor sit amet " * 30000)   # ~810 KB, over the 512 KiB cap

function Write-Text($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }

function Version-Of($exe) { try { (Get-Item $exe).VersionInfo.ProductVersion } catch { '' } }

function Close-Probe-Windows {
  Get-Process | Where-Object { $_.MainWindowTitle -match '^cgprobe-' } |
    ForEach-Object { [void]$_.CloseMainWindow() }
}

function Activate($title, $exeName) {
  # Find the app's own window by process name + anchored title, then activate by PID.
  # Activating by title alone can pick a shell proxy window (e.g. Edge's
  # explorer.exe TabProxyWindow) that shares the title.
  $base = [IO.Path]::GetFileNameWithoutExtension($exeName)
  $proc = Get-Process -Name $base -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "$title*" } | Select-Object -First 1
  if (-not $proc) { return $false }
  try { [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id); return $true } catch { return $false }
}

function Trial($label, $title, $exeName, $keys, $version, $n) {
  Start-Sleep -Milliseconds 1200
  if (-not (Activate $title $exeName)) { Write-Warning "${label} trial ${n}: cannot activate '$title' ($exeName); skipped"; return }
  Start-Sleep -Milliseconds 700
  foreach ($k in $keys) { [Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 300 }
  Start-Sleep -Milliseconds 400
  $argList = @('--after', '1', '--csv', "`"$Csv`"", '--label', $label, '--trial', $n,
               '--app-version', "`"$version`"", '--expect-exe', $exeName)
  Start-Process -FilePath $Prober -ArgumentList $argList -WindowStyle Hidden -Wait
}

function Run($label, $title, $exeName, $keys, $version) {
  Write-Host "== $label ($Trials trials)"
  for ($n = 1; $n -le $Trials; $n++) { Trial $label $title $exeName $keys $version $n }
}

try {
  if ($Apps -contains 'notepad') {
    $f = Join-Path $Work 'cgprobe-notepad.txt'; Write-Text $f $sample
    Start-Process notepad.exe $f; Start-Sleep 2
    Run 'notepad' 'cgprobe-notepad' 'notepad.exe' '^a' (Version-Of "$env:WINDIR\System32\notepad.exe")
    Close-Probe-Windows
  }
  if ($Apps -contains 'notepad-overcap') {
    $f = Join-Path $Work 'cgprobe-notepad-overcap.txt'; Write-Text $f $big
    Start-Process notepad.exe $f; Start-Sleep 3
    Run 'notepad-overcap' 'cgprobe-notepad-overcap' 'notepad.exe' '^a' (Version-Of "$env:WINDIR\System32\notepad.exe")
    Close-Probe-Windows
  }
  if ($Apps -contains 'winforms') {
    $form = Join-Path $Work 'form.ps1'
    Write-Text $form @'
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form
$r = New-Object Windows.Forms.RichTextBox
$r.Dock = "Fill"
$r.Text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "sample.txt"))
$f.Controls.Add($r); $f.Text = "cgprobe-winforms"
$f.Add_Shown({ $r.Focus() })
[void]$f.ShowDialog()
'@
    Write-Text (Join-Path $Work 'sample.txt') $sample
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $form -PassThru; Start-Sleep 3
    Run 'winforms-richedit' 'cgprobe-winforms' 'pwsh.exe' '^a' $PSVersionTable.PSVersion.ToString()
    if (-not $p.HasExited) { [void]$p.CloseMainWindow(); Start-Sleep 1; if (-not $p.HasExited) { $p.Kill() } }
  }
  foreach ($b in @(
      @{ n = 'edge'; exe = 'msedge.exe'; path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" },
      @{ n = 'chrome'; exe = 'chrome.exe'; path = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" })) {
    $variants = if ($b.n -eq 'edge') { @('edge', 'edge-overcap', 'edge-password') } else { @('chrome') }
    foreach ($v in $variants) {
      if ($Apps -notcontains $v -or -not (Test-Path $b.path)) { continue }
      $html = Join-Path $Work "cgprobe-$v.html"
      $body = switch ($v) {
        'edge-overcap' { "<pre>$big</pre>" }
        'edge-password' { "<input type=password id=p autofocus value=secret-sample>" }
        default { "<pre>$sample</pre>" }
      }
      Write-Text $html "<html><head><meta charset=utf-8><title>cgprobe-$v</title></head><body>$body</body></html>"
      $profile = Join-Path $Work "profile-$v"
      Start-Process $b.path -ArgumentList "--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check', '--new-window', "file:///$($html -replace '\\','/')"
      Start-Sleep 5
      Run $v "cgprobe-$v" $b.exe '^a' (Version-Of $b.path)
      Close-Probe-Windows
      Start-Sleep 1
    }
  }
  if ($Apps -contains 'vscode') {
    $code = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
    if (Test-Path $code) {
      $f = Join-Path $Work 'cgprobe-vscode.txt'; Write-Text $f $sample
      # Quiet throwaway profile so the editor, not a welcome/onboarding view, has focus.
      $ud = Join-Path $Work 'vscode-data'
      New-Item -ItemType Directory -Force -Path (Join-Path $ud 'User') | Out-Null
      Write-Text (Join-Path $ud 'User\settings.json') '{"workbench.startupEditor":"none","security.workspace.trust.enabled":false,"telemetry.telemetryLevel":"off","chat.disableAIFeatures":true,"update.mode":"none"}'
      Start-Process "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" -ArgumentList '-n', "`"$f`"", '--user-data-dir', "`"$ud`"" -WindowStyle Hidden
      Start-Sleep 8
      Run 'vscode' 'cgprobe-vscode' 'Code.exe' @('^1', '^a') (Version-Of $code)
      Close-Probe-Windows
    }
  }
  if ($Apps -contains 'word') {
    $word = "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE"
    if (Test-Path $word) {
      $f = Join-Path $Work 'cgprobe-word.txt'; [IO.File]::WriteAllText($f, $sample, (New-Object Text.UTF8Encoding($true)))
      Start-Process $word -ArgumentList "`"$f`""
      Start-Sleep 9
      Run 'word' 'cgprobe-word' 'WINWORD.EXE' '^a' (Version-Of $word)
      Close-Probe-Windows
    }
  }
  if ($Apps -contains 'terminal') {
    $wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    if ($wt) {
      $cmd = "`$Host.UI.RawUI.WindowTitle='cgprobe-terminal'; 1..200 | % { 'terminal line ' + `$_ }; Start-Sleep 600"
      Start-Process $wt -ArgumentList '-w', 'new', 'new-tab', '--title', 'cgprobe-terminal', '--suppressApplicationTitle', 'pwsh', '-NoLogo', '-NoProfile', '-Command', "`"$cmd`""
      Start-Sleep 6
      Run 'windows-terminal' 'cgprobe-terminal' 'WindowsTerminal.exe' '^+a' (Version-Of $wt)
      Close-Probe-Windows
    }
  }
}
finally {
  Close-Probe-Windows
  Write-Host "Results appended to $Csv (sample files in $Work can be deleted)"
}

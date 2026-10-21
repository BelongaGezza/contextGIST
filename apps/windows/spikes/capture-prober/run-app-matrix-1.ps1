param([string]$Prober, [string]$Csv)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$dir = Split-Path $Csv
$sample = (1..300 | ForEach-Object { "The quick brown fox jumps over the lazy dog." }) -join " "
$txt = Join-Path $dir "sample.txt"; Set-Content $txt $sample
$html = Join-Path $dir "sample.html"
Set-Content $html "<html><body><p id=p>$sample</p><input type=password id=pw value=secret></body></html>"

function Probe($label, $title, $keys) {
  Start-Sleep -Seconds 2
  try { [Microsoft.VisualBasic.Interaction]::AppActivate($title) } catch { Write-Host "${label}: AppActivate failed" }
  Start-Sleep -Milliseconds 800
  if ($keys) { [System.Windows.Forms.SendKeys]::SendWait($keys) }
  Start-Sleep -Milliseconds 500
  # prober runs in this foreground-less child; it reads the system-wide focused element
  $p = Start-Process -FilePath $Prober -ArgumentList "--after 1 --csv `"$Csv`"" -PassThru -WindowStyle Hidden -Wait
  Write-Host "== $label done"
}

# 1. Notepad
$n = Start-Process notepad.exe $txt -PassThru
Probe "notepad" "sample.txt" "^a"

# 2. WinForms RichTextBox hosted in a separate powershell
$formScript = Join-Path $dir "form.ps1"
@'
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form
$r = New-Object Windows.Forms.RichTextBox
$r.Dock = "Fill"
$r.Text = Get-Content (Join-Path $PSScriptRoot "sample.txt") -Raw
$f.Controls.Add($r); $f.Text = "wfprobe"
$f.Add_Shown({ $r.Focus() })
[void]$f.ShowDialog()
'@ | Set-Content $formScript
$wf = Start-Process pwsh -ArgumentList '-NoProfile','-File',$formScript -PassThru
Start-Sleep -Seconds 3
Probe "winforms-richtextbox" "wfprobe" "^a"
$null = $wf.CloseMainWindow(); Start-Sleep 1; if(!$wf.HasExited){$wf.Kill()}

# 3. Edge page text, then password field
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$e = Start-Process $edge "--new-window `"file:///$($html -replace '\\','/')`"" -PassThru
Start-Sleep -Seconds 4
Probe "edge-page" "sample" "^a"
Probe "edge-page-again" "sample" "^a"
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait("{TAB}")
Probe "edge-password-field" "sample" "^a"
Start-Sleep 1
Get-Process notepad,msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match "^sample" } | ForEach-Object { [void]$_.CloseMainWindow() }


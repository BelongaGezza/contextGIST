param([string]$Prober, [string]$Csv)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$dir = Split-Path $Csv
$sample = (1..300 | ForEach-Object { "The quick brown fox jumps over the lazy dog." }) -join " "

function Probe($label, $title, $keys, $warm) {
  Start-Sleep -Seconds 2
  try { [Microsoft.VisualBasic.Interaction]::AppActivate($title) } catch { Write-Host "${label}: AppActivate failed" }
  Start-Sleep -Milliseconds 800
  if ($keys) { [System.Windows.Forms.SendKeys]::SendWait($keys) }
  Start-Sleep -Milliseconds 500
  Start-Process -FilePath $Prober -ArgumentList "--after 1 --csv `"$Csv`"" -WindowStyle Hidden -Wait
  Write-Host "== $label done"
}
function CloseByTitle($rx) {
  Get-Process | Where-Object { $_.MainWindowTitle -match $rx } | ForEach-Object { [void]$_.CloseMainWindow() }
}

# Chrome (fresh page; Chromium a11y may need warming)
$h = Join-Path $dir "chromeprobe.html"
Set-Content $h "<html><head><title>chromeprobe</title></head><body><p>$sample</p></body></html>"
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" "--new-window `"file:///$($h -replace '\\','/')`""
Start-Sleep -Seconds 4
Probe "chrome-first" "chromeprobe" "^a"
Probe "chrome-second" "chromeprobe" "^a"
CloseByTitle "^chromeprobe"

# VS Code (Electron)
$t = Join-Path $dir "vscodeprobe.txt"; Set-Content $t $sample
Start-Process "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" "-n `"$t`"" -WindowStyle Hidden
Start-Sleep -Seconds 6
Probe "vscode-first" "vscodeprobe" "^a"
Probe "vscode-second" "vscodeprobe" "^a"
CloseByTitle "vscodeprobe"

# Word
$w = Join-Path $dir "wordprobe.txt"; Set-Content $w $sample
Start-Process "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE" "`"$w`""
Start-Sleep -Seconds 8
Probe "word" "wordprobe" "^a"
CloseByTitle "wordprobe"

# Windows Terminal (select all = Ctrl+Shift+A)
Start-Process wt.exe "-w new --title wtprobe pwsh -NoLogo -NoProfile -Command `"1..200 | % { 'terminal line ' + `$_ }; Start-Sleep 60`""
Start-Sleep -Seconds 5
Probe "windows-terminal" "wtprobe" "^+a"
CloseByTitle "wtprobe"

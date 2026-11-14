# restarts the laptop's DeskView in the signed-in session; -Qa: with DESKVIEW_QA_INPUT=1 (injected test input counts as real)
param([switch]$Qa)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'DeskView\.ps1' -and $_.CommandLine -notmatch 'Setup' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1
$run = 'C:\Users\Public\dvqa-start.cmd'
Set-Content $run ("@echo off`r`n" + $(if ($Qa) { "set DESKVIEW_QA_INPUT=1`r`n" } else { "" }) + 'start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\DeskView\DeskView.ps1 -Tray') -Encoding ASCII
schtasks /Create /TN DeskViewStartQa /TR $run /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-Null
schtasks /Run /TN DeskViewStartQa 2>&1 | Out-Null
Start-Sleep 8
schtasks /Delete /TN DeskViewStartQa /F 2>&1 | Out-Null
"DeskView running on the laptop: $([bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'DeskView\.ps1' })) (QA input: $Qa)"

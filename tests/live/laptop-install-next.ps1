$out = 'C:\Users\Public\dv-install.txt'
if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }
Set-Content C:\Users\Public\dv-install-run.ps1 @"
`$ProgressPreference = 'SilentlyContinue'
iwr https://raw.githubusercontent.com/xl337x/DeskView/next/install.ps1 -OutFile `$env:TEMP\dv-install.ps1 -UseBasicParsing
& powershell -NoProfile -ExecutionPolicy Bypass -File `$env:TEMP\dv-install.ps1 -Ref next -Role Client -PairCode <PAIRCODE> -ServerAddress 10.0.0.10 *> '$out'
'INSTALL DONE' | Add-Content '$out'
"@
schtasks /Create /TN DeskViewInstallNext /TR 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\dv-install-run.ps1' /SC ONCE /ST 23:59 /IT /RL HIGHEST /F 2>&1 | Out-Null
schtasks /Run /TN DeskViewInstallNext 2>&1 | Out-Null
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 300) {
    if ((Test-Path $out) -and ((Get-Content $out -Raw) -match 'INSTALL DONE')) { break }
    Start-Sleep 3
}
schtasks /Delete /TN DeskViewInstallNext /F 2>&1 | Out-Null
if (Test-Path $out) { Get-Content $out } else { 'no output' }
Start-Sleep 8
'--- running DeskView:'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'DeskView\.ps1' } | % { $_.ProcessId.ToString() + ' ' + $_.CommandLine }
'--- app log:'
$log = '$env:APPDATA\DeskView\deskview.log'
if (Test-Path $log) { Get-Content $log -Tail 12 }
'--- app settings:'
$a = '$env:APPDATA\DeskView\app.json'
if (Test-Path $a) { (Get-Content $a -Raw | ConvertFrom-Json) | Select Role, InputEngine, ServerAddress, PairCode, RemoteName, SetupDone, ComputerName | Format-List | Out-String }

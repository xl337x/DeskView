# Runs a script file in the laptop's signed-in desktop session (scheduled task, interactive) and prints what it wrote.
param([string]$Script, [int]$Wait = 60)
$name = [IO.Path]::GetFileNameWithoutExtension($Script); $out = "C:\Users\Public\$name.out.txt"; $task = "DeskViewQA-$name"
if (Test-Path $out) { Remove-Item $out }
$wrap = "C:\Users\Public\$name.wrap.ps1"
Set-Content $wrap "& '$Script' *> '$out'; 'RUN DONE' | Add-Content '$out'"
schtasks /Create /TN $task /TR "powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $wrap" /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-Null
schtasks /Run /TN $task 2>&1 | Out-Null
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $Wait) { if ((Test-Path $out) -and ((Get-Content $out -Raw) -match 'RUN DONE')) { break }; Start-Sleep -Milliseconds 300 }
schtasks /Delete /TN $task /F 2>&1 | Out-Null
if (Test-Path $out) { Get-Content $out } else { 'no output' }

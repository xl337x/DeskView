# kills the laptop's sender for screen 2 (port 9001) - DeskView must start a new one and the server's picture must come back
$p = Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -match ':9001\?' }
foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force; "killed sender $($x.ProcessId) at $(Get-Date -Format HH:mm:ss.fff)" }
if (-not $p) { 'no sender for screen 2 found' }

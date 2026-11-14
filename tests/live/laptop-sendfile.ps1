# the laptop -> the server: send a test file with DeskView's own transfer code (the installed copy) and report the result
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path $env:LOCALAPPDATA\DeskView\DeskView-Input.cs -ReferencedAssemblies System.Windows.Forms, System.Drawing
$f = "C:\Users\Public\dvqa-from-the laptop-$(Get-Date -Format HHmmss).bin"
$bytes = New-Object byte[] (2 * 1024 * 1024 + 77); (New-Object Random 42).NextBytes($bytes); [IO.File]::WriteAllBytes($f, $bytes)
$sw = [Diagnostics.Stopwatch]::StartNew()
$err = [DeskViewFiles]::Send($env:DV_SERVER_IP, 9002, $env:DESKVIEW_PAIRCODE, [string[]]@($f), $null)
"sent $(Split-Path $f -Leaf) ($($bytes.Length) bytes) in $($sw.ElapsedMilliseconds) ms; result: $(if ($err) { $err } else { 'confirmed by the other computer' })"
"sha256 $((Get-FileHash $f).Hash)"

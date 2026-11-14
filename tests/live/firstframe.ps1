# Precise: ms from process start until the first decoded frame's bytes arrive on stdout (rawvideo pipe).
param([int]$Port = 9001, [string]$Extra = '', [string]$Fflags = '-fflags nobuffer', [int]$Runs = 2, [int]$Gap = 3, [string]$Ffmpeg = '$env:LOCALAPPDATA\DeskView\ffmpeg\ffmpeg.exe')
$url = "srt://${env:DV_LAPTOP_IP}:$($Port)?mode=caller&latency=40000&transtype=live&connect_timeout=3000&passphrase=<VIDEO-KEY>&pbkeylen=32"
for ($r = 1; $r -le $Runs; $r++) {
  $psi = New-Object Diagnostics.ProcessStartInfo $Ffmpeg, "-hide_banner -loglevel error $Fflags -flags low_delay -probesize 32768 -analyzeduration 0 $Extra -i `"$url`" -frames:v 1 -vf scale=64:36 -f rawvideo -pix_fmt gray -"
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $sw = [Diagnostics.Stopwatch]::StartNew(); $p = [Diagnostics.Process]::Start($psi)
  $buf = New-Object byte[] 4096; $task = $p.StandardOutput.BaseStream.ReadAsync($buf, 0, 4096)
  $ok = $task.Wait(12000); $t = $sw.ElapsedMilliseconds
  "port $Port [$Extra] run $r : first frame bytes at $(if ($ok -and $task.Result -gt 0) { "$t ms" } else { "none within 12 s" })"
  try { $p.Kill() } catch { }; Start-Sleep $Gap
}



# Video latency on the server alone (loopback, no network): a test window on the main monitor flips colour; a player of
# the server's own stream of that monitor (as DeskView starts it) sits small on another monitor; time until it shows the flip.
param([string]$PlayerArgs = '', [int]$Latency = 40, [int]$Flips = 10, [string]$Label = 'as DeskView plays it', [string]$SenderExtra = '', [switch]$Stall, [string]$EncArgs = '-c:v h264_qsv -preset veryfast -look_ahead 0 -async_depth 1 -b:v 20M -maxrate 20M -bufsize 10000k -g 30 -bf 0')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path "$env:LOCALAPPDATA\DeskView\DeskView-Portal.cs" -ReferencedAssemblies System.Windows.Forms, System.Drawing 2>&1 | Out-Null
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Px {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h); [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
  public static int Green(int x, int y) { var dc = GetDC(IntPtr.Zero); uint c = GetPixel(dc, x, y); ReleaseDC(IntPtr.Zero, dc); return (int)((c >> 8) & 0xFF); }
}
'@
[void][Px]::SetProcessDpiAwarenessContext([IntPtr](-4))
$mons = [Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
$prim = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $other = ($mons | ? { -not $_.Primary } | Select -Last 1).Bounds
$f = New-Object Windows.Forms.Form -Property @{ FormBorderStyle = 'None'; StartPosition = 'Manual'; TopMost = $true; ShowInTaskbar = $false; BackColor = [Drawing.Color]::FromArgb(37, 99, 235) }
$f.Bounds = New-Object Drawing.Rectangle ($prim.X + 200), ($prim.Y + 200), 400, 300
$f.Show(); [Windows.Forms.Application]::DoEvents()
$key = (Get-Content "$env:APPDATA\DeskView\app.json" -Raw | ConvertFrom-Json).PairCode
$sha = [Security.Cryptography.SHA256]::Create(); $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('DeskView-video-v2:' + $key.Trim().ToUpper())); $vk = -join ($h[0..15] | % { $_.ToString('x2') })
# a test sender of the main monitor (DeskView's own senders are left alone), as DeskView starts one plus $SenderExtra
$outs = & "$env:LOCALAPPDATA\DeskView\ffmpeg\ffmpeg.exe" -hide_banner -f lavfi -i ddagrab=list_outputs=1 2>&1 | Out-String
$idx = 0
$sa = "-hide_banner -loglevel error -nostats -f lavfi -i ddagrab=output_idx=$($idx):framerate=60:draw_mouse=1,hwmap=derive_device=qsv,format=qsv $EncArgs -flush_packets 1 $SenderExtra -f mpegts -mpegts_flags resend_headers `"srt://0.0.0.0:9077?mode=listener&latency=$($Latency * 1000)&pkt_size=1316&transtype=live&passphrase=$vk&pbkeylen=32`""
$spsi = New-Object Diagnostics.ProcessStartInfo "$env:LOCALAPPDATA\DeskView\ffmpeg\ffmpeg.exe", $sa; $spsi.UseShellExecute = $false; $spsi.CreateNoWindow = $true
if ($SenderExtra -ne 'own') { $sender = [Diagnostics.Process]::Start($spsi); Start-Sleep -Milliseconds 1500 } else { $sender = $null }
$port = if ($SenderExtra -eq 'own') { 9000 } else { 9077 }; $url = "srt://127.0.0.1:$($port)?mode=caller&latency=$($Latency * 1000)&transtype=live&connect_timeout=3000&passphrase=$vk&pbkeylen=32"
$px = $other.X + 20; $py = $other.Y + 400
$a = "-hide_banner -loglevel error -nostats -fflags discardcorrupt -flags low_delay -framedrop -sync ext -probesize 32768 -analyzeduration 0 -an -noborder $PlayerArgs -left $px -top $py -x 480 -y 270 -window_title DVLAT `"$url`""
$psi = New-Object Diagnostics.ProcessStartInfo "$env:LOCALAPPDATA\DeskView\ffmpeg\ffplay.exe", $a; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$w = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt 10000 -and $w -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 20; $w = [DeskViewPortal]::FindVisibleWindow($p.Id, 'DVLAT') }
$host2 = New-Object DeskViewPictureHost (New-Object Drawing.Rectangle $px, $py, 480, 270); [void]$host2.Adopt($w)
for ($i = 0; $i -lt 30; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
# the test window's middle, as it appears in the small picture (the main monitor scaled into 480x270)
$sx = $px + [int]((400) * 480 / $prim.Width); $sy = $py + [int]((350) * 270 / $prim.Height)
$lat = @()
if ($Stall) { Add-Type -Name N -Namespace X -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h); [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);'; [void][X.N]::NtSuspendProcess($p.Handle); Start-Sleep -Milliseconds 1500; [void][X.N]::NtResumeProcess($p.Handle); for ($i = 0; $i -lt 20; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } }
for ($i = 0; $i -lt $Flips; $i++) {
    $before = [Px]::Green($sx, $sy)
    $f.BackColor = if ($f.BackColor.G -lt 120) { [Drawing.Color]::FromArgb(22, 163, 74) } else { [Drawing.Color]::FromArgb(37, 99, 235) }; $f.Refresh()
    $s2 = [Diagnostics.Stopwatch]::StartNew()
    while ($s2.ElapsedMilliseconds -lt 3000 -and [math]::Abs([Px]::Green($sx, $sy) - $before) -lt 40) { [Windows.Forms.Application]::DoEvents() }
    $lat += $s2.ElapsedMilliseconds
    for ($k = 0; $k -lt 6; $k++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
}
$p.Kill(); try { $sender.Kill() } catch { }; $host2.Close(); $f.Close()
$s = $lat | Sort-Object
"{0,-34} median {1,4} ms  best {2,4}  worst {3,4}   ({4})" -f $Label, $s[[int]($s.Count / 2)], $s[0], $s[-1], ($lat -join ',')

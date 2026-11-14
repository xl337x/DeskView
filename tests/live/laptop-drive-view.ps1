# the laptop controls the server: view the server's main monitor (as Ctrl+Alt+1 does), click into the test window there, type, measure
# key-press -> picture-change latency on the laptop's own screen, copy on the server, come back. the laptop's DeskView runs with
# DESKVIEW_QA_INPUT=1 so this injected input counts as real.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Runtime.InteropServices;
public static class Q {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
  public static int Green(int x, int y) { var dc = GetDC(IntPtr.Zero); uint c = GetPixel(dc, x, y); ReleaseDC(IntPtr.Zero, dc); return (int)((c >> 8) & 0xFF); }
}
'@
[void][Q]::SetProcessDpiAwarenessContext([IntPtr](-4))
function T { Get-Date -Format HH:mm:ss.fff }
function Key($vk, $up) { [Q]::keybd_event($vk, 0, $(if ($up) { 2 } else { 0 }), [UIntPtr]::Zero); Start-Sleep -Milliseconds 30 }
function Tap($vk) { Key $vk $false; Key $vk $true }
$p = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $cx = $p.X + [int]($p.Width / 2); $cy = $p.Y + [int]($p.Height * 0.62)
$clipLaptop = "QA clipboard from the laptop $(T)"; [Windows.Forms.Clipboard]::SetText($clipLaptop); "$(T) the laptop clipboard set: $clipLaptop"
$cmd = Join-Path $env:APPDATA 'DeskView\command.txt'
$sw = [Diagnostics.Stopwatch]::StartNew(); Set-Content $cmd '1' -Encoding ASCII; "$(T) asked DeskView to view the server's monitor 1"
# the picture is there when the test window's blue shows where it sits
$g0 = [Q]::Green($cx, $cy); while ($sw.ElapsedMilliseconds -lt 15000) { $g = [Q]::Green($cx, $cy); if ([math]::Abs($g - 99) -lt 25) { break }; Start-Sleep -Milliseconds 10 }
"$(T) the server's picture showing after $($sw.ElapsedMilliseconds) ms (green value $g)"
# click into the text box (absolute move inside the picture; the picture covers this screen)
$ax = [int](($cx - [Windows.Forms.SystemInformation]::VirtualScreen.X) * 65535 / ([Windows.Forms.SystemInformation]::VirtualScreen.Width - 1))
$tby = $p.Y + [int]($p.Height * (140 + 25) / 1080); $ay = [int](($tby - [Windows.Forms.SystemInformation]::VirtualScreen.Y) * 65535 / ([Windows.Forms.SystemInformation]::VirtualScreen.Height - 1))
[Q]::mouse_event(0x8001 -bor 0x4000, $ax, $ay, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 200
[Q]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [Q]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 400
"$(T) typing on the server"
foreach ($c in 'FROMLAPTOP'.ToCharArray()) { Tap ([byte][char]$c) }
Start-Sleep -Milliseconds 400
# latency: F9 switches the server window's colour; time until this screen shows the switch
$lat = @()
for ($i = 0; $i -lt 12; $i++) {
    $before = [Q]::Green($cx, $cy); $s2 = [Diagnostics.Stopwatch]::StartNew(); Tap 0x78
    while ($s2.ElapsedMilliseconds -lt 3000 -and [math]::Abs([Q]::Green($cx, $cy) - $before) -lt 40) { }
    $lat += $s2.ElapsedMilliseconds; Start-Sleep -Milliseconds 350
}
"$(T) key press on the laptop -> the server -> picture back on the laptop (ms): $($lat -join ', ')"
$sorted = $lat | Sort-Object; "    median $($sorted[[int]($sorted.Count / 2)]) ms, best $($sorted[0]) ms, worst $($sorted[-1]) ms"
"$(T) select the typed line and copy it on the server"
Key 0x10 $false; [Q]::keybd_event(0x24, 0x47, 1, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30; [Q]::keybd_event(0x24, 0x47, 3, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30; Key 0x10 $true
Key 0x11 $false; Tap 0x43; Key 0x11 $true; Start-Sleep -Milliseconds 600
Set-Content $cmd 'off' -Encoding ASCII; "$(T) back to this laptop (view off)"
Start-Sleep -Milliseconds 2000
"$(T) the laptop clipboard now: [$([Windows.Forms.Clipboard]::GetText())]"

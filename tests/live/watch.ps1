# Watches the server's monitors: every ~150 ms, how much of each monitor shows the QA test window colours
# (blue 37,99,235 = "win", green 22,163,74 = "slide"), and how many DeskView picture hosts / ffplay exist.
# One line per sample when something changed: time  m1=blue/green  m2=..  m3=..  hosts=N ffplay=N
param([string]$Log = "$PSScriptRoot\watch.log", [int]$Seconds = 600)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class Px {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  // samples every 8th pixel; returns "blue/green" counts of samples near the two test colours
  public static string Count(Rectangle r) {
    using (var b = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size);
      var d = b.LockBits(new Rectangle(0, 0, r.Width, r.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      int blue = 0, green = 0; var row = new byte[d.Stride];
      for (int y = 40; y < r.Height; y += 8) {
        Marshal.Copy(d.Scan0 + y * d.Stride, row, 0, d.Stride);
        for (int x = 0; x < r.Width; x += 8) {
          int B = row[x * 4], G = row[x * 4 + 1], R = row[x * 4 + 2];
          if (Math.Abs(R - 37) < 30 && Math.Abs(G - 99) < 30 && Math.Abs(B - 235) < 30) blue++;
          else if (Math.Abs(R - 22) < 30 && Math.Abs(G - 163) < 30 && Math.Abs(B - 74) < 30) green++;
        }
      }
      b.UnlockBits(d); return blue + "/" + green;
    }
  }
}
'@
[void][Px]::SetProcessDpiAwarenessContext([IntPtr](-4))
$mons = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
"$(Get-Date -Format HH:mm:ss.fff) start monitors: $(($mons | % { $_.DeviceName -replace '.*\\','' }) -join ',')" | Add-Content $Log
$last = ''; $end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $parts = for ($i = 0; $i -lt $mons.Count; $i++) { "m$($i+1)=" + [Px]::Count($mons[$i].Bounds) }
    $ff = @(Get-Process ffplay -ErrorAction SilentlyContinue).Count
    # bucket the counts so tiny compression changes don't spam the log
    $key = (($parts | % { $n = $_ -split '[=/]'; "$($n[0])=$([math]::Min(2,[int]([int]$n[1]/800)))/$([math]::Min(2,[int]([int]$n[2]/800)))" }) -join ' ') + " ffplay=$ff"
    if ($key -ne $last) { "$(Get-Date -Format HH:mm:ss.fff) $($parts -join ' ') ffplay=$ff" | Add-Content $Log; $last = $key }
    Start-Sleep -Milliseconds 100
}

<#
  Live tests for the portal (run on the Deskflow SERVER with DeskView running and the client connected).
  Simulates mouse moves into / out of the portal monitor and checks Deskflow's log for the hand-overs.
  Your mouse moves by itself for a few seconds per monitor.

    tests\portal.tests.ps1            test the monitor DeskView currently shows the client on
    tests\portal.tests.ps1 -All       move the client to every monitor in turn and test each, then restore
#>
param([switch]$All)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PT {
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public int dx; [FieldOffset(12)] public int dy; [FieldOffset(20)] public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int cb);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  public static void Rel(int dx, int dy) { var a = new IN[1]; a[0].dx = dx; a[0].dy = dy; a[0].flags = 1; SendInput(1, a, 40); }
}
'@
[void][PT]::SetThreadDpiAwarenessContext([IntPtr]-4)    # physical pixels, like DeskView
$pt = New-Object PT+POINT
$log = 'C:\ProgramData\Deskflow\deskflow-daemon.log'
$settingsFile = Join-Path $env:APPDATA 'DeskView\settings.json'
$app = Join-Path $env:LOCALAPPDATA 'DeskView\DeskView.ps1'
$script:pass = 0; $script:fail = 0

function Settings { Get-Content $settingsFile -Raw | ConvertFrom-Json }
$remote = (Settings).RemoteName
if (-not $remote) {
    $remote = Select-String -Path (Join-Path $env:APPDATA 'Deskflow\Deskflow.conf') -Pattern '^\[computer_(.+)\]$' |
              % { $_.Matches[0].Groups[1].Value } | ? { $_ -ne $env:COMPUTERNAME } | Select -First 1
}
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
$VL = ($screens | % { $_.Bounds.Left } | Measure -Minimum).Minimum
$VR = ($screens | % { $_.Bounds.Right } | Measure -Maximum).Maximum

function Since($n0, $pat) { @(Get-Content $log | Select -Skip $n0 | Select-String $pat) }
function Near($a, $b, $tol = 6) { [math]::Abs($a - $b) -le $tol }

# $want: 'left' / 'right' = the remote cursor must land on that remote edge at height $y and come back at $backX;
#        'none' = no hand-over may happen.
function Trip($label, $startX, $y, $inDir, $outDir, $want, $backX) {
    $n0 = (Get-Content $log).Count
    [void][PT]::SetCursorPos($startX, $y); Start-Sleep -Milliseconds 250
    for ($i = 0; $i -lt 40; $i++) { [PT]::Rel(10 * $inDir, 0); Start-Sleep -Milliseconds 50; if (Since $n0 "to `"$remote`"") { break } }
    Start-Sleep -Milliseconds 300
    $in = Since $n0 "to `"$remote`"" | Select -First 1
    $e = if ($in) { [regex]::Match($in.Line, 'at (-?\d+),(-?\d+)').Groups | Select -Skip 1 | % { [int]$_.Value } } else { $null }
    if ($in -and $outDir -ne 0) {
        for ($i = 0; $i -lt 200; $i++) { [PT]::Rel(20 * $outDir, 0); Start-Sleep -Milliseconds 30; if (Since $n0 "to `"$env:COMPUTERNAME`"") { break } }
        Start-Sleep -Milliseconds 300
    }
    [void][PT]::GetCursorPos([ref]$pt)
    # Where control came back, as Deskflow reports it (the test keeps moving for a few steps after that).
    $out = Since $n0 "to `"$env:COMPUTERNAME`"" | Select -First 1
    $b = if ($out) { [regex]::Match($out.Line, 'at (-?\d+),(-?\d+)').Groups | Select -Skip 1 | % { [int]$_.Value } } else { $null }
    if ($b) { $pt.X = $b[0]; $pt.Y = $b[1] }
    # Entering lands at the point crossed: within a step or two of the remote edge (exactly on it with the
    # edge-based portal, a few pixels in with Deskflow's native portal).
    $ok = switch ($want) {
        'none'  { -not $e }
        'left'  { $e -and $e[0] -le 25 -and (Near $e[1] $y) -and $b -and (Near $pt.X $backX 3) -and (Near $pt.Y $y) }
        'right' { $e -and $e[0] -gt 100 -and (Near $e[1] $y) -and $b -and (Near $pt.X $backX 3) -and (Near $pt.Y $y) }
    }
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "{0}  {1}`n      {2} entry: {3}   back at: {4},{5}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label, $remote, $(if ($e) { "$($e[0]),$($e[1])" } else { 'none' }), $pt.X, $pt.Y
}

function Test-Monitor($scr) {
    $P = $scr.Bounds
    $name = $scr.DeviceName -replace '^\\\\\.\\', ''
    "--- portal on $name ($($P.Left)..$($P.Right - 1)) ---"
    $hasLeft = $P.Left -gt $VL; $hasRight = $P.Right -lt $VR
    $y1 = $P.Top + [int]($P.Height * 0.3); $y2 = $P.Top + [int]($P.Height * 0.6)
    if ($hasLeft) {
        Trip "enter from the left at y=$y1, leave $remote's left edge -> back beside it at x~$($P.Left - 1)" ($P.Left - 120) $y1 1 -1 'left' ($P.Left - 1)
    }
    if ($hasRight) {
        Trip "enter from the right at y=$y2, leave $remote's right edge -> back beside it at x~$($P.Right)" ($P.Right + 120) $y2 -1 1 'right' ($P.Right)
    }
    if ($hasLeft -and $VR -gt $P.Right) {
        Trip "outer right edge must not switch" ($VR - 160) $y1 1 0 'none' 0
    }
    if ($hasRight -and $VL -lt $P.Left) {
        Trip "outer left edge must not switch" ($VL + 160) $y1 -1 0 'none' 0
    }
}

$current = (Settings).Monitor
if ($All) {
    $n = 0
    foreach ($scr in $screens) {
        $n++
        & powershell -NoProfile -ExecutionPolicy Bypass -File $app -Show $n
        Start-Sleep 25                       # Deskflow restarts with the new links and the client reconnects
        Test-Monitor $scr
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $app -Show $current
} else {
    $scr = $screens | ? { ($_.DeviceName -replace '^\\\\\.\\', '') -eq $current } | Select -First 1
    if (-not $scr) { throw "DeskView is not showing $remote on any monitor (Monitor=$current)." }
    Test-Monitor $scr
}
[void][PT]::SetCursorPos($screens[0].Bounds.Left + 200, $screens[0].Bounds.Top + 200)
"== portal: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

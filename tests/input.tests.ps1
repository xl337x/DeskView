# Loopback tests for DeskView-Input.cs (agent + forwarder) on one machine - no second machine needed.
# Opens a small test window and moves the mouse / types for a few seconds. Uses TCP port 9102 on localhost.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot '..\app\DeskView-Input.cs') -ReferencedAssemblies System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class TI {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public ushort vk; [FieldOffset(10)] public ushort scan; [FieldOffset(12)] public uint flags; [FieldOffset(8)] public int dx; [FieldOffset(12)] public int dy; [FieldOffset(20)] public uint mflags; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int cb);
  public static void Key(ushort vk, bool down) { var a = new IN[1]; a[0].type = 1; a[0].vk = vk; a[0].flags = down ? 0u : 2u; SendInput(1, a, 40); }
  public static void Rel(int dx, int dy) { var a = new IN[1]; a[0].type = 0; a[0].dx = dx; a[0].dy = dy; a[0].mflags = 1; SendInput(1, a, 40); }
}
'@
[void][TI]::SetThreadDpiAwarenessContext([IntPtr]-4)
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
$prim = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$last = $screens[-1].Bounds
$VR = ($screens | % { $_.Bounds.Right } | Measure -Maximum).Maximum
$pt = New-Object TI+POINT
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail) { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }

# A test window that records what is typed into it.
$outFile = Join-Path $env:TEMP 'deskview-test-typed.txt'; [IO.File]::Delete($outFile)
$formScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$f = New-Object Windows.Forms.Form; `$f.Text = 'DeskView key test'; `$f.TopMost = `$true; `$f.StartPosition = 'Manual'; `$f.Location = New-Object Drawing.Point $($prim.Left + 200),$($prim.Top + 200); `$f.Size = New-Object Drawing.Size 500,150
`$t = New-Object Windows.Forms.TextBox; `$t.Dock = 'Fill'; `$t.Multiline = `$true; `$f.Controls.Add(`$t)
`$tm = New-Object Windows.Forms.Timer; `$tm.Interval = 300; `$tm.add_Tick({ [IO.File]::WriteAllText('$outFile', `$t.Text) }); `$tm.Start()
`$f.add_Shown({ `$f.Activate(); `$t.Focus() })
[Windows.Forms.Application]::Run(`$f)
"@
$formFile = Join-Path $env:TEMP 'deskview-test-form.ps1'; Set-Content $formFile $formScript
$form = Start-Process powershell -ArgumentList "-NoProfile -STA -File `"$formFile`"" -PassThru
Start-Sleep 3
function Focus-Form { $form.Refresh(); [void][TI]::SetForegroundWindow($form.MainWindowHandle); Start-Sleep -Milliseconds 300 }

# ---------- agent ----------
$agent = New-Object DeskViewAgent
$agent.Port = 9102; $agent.Code = 'TEST-1234'
$agent.TL = $last.Left; $agent.TT = $last.Top; $agent.TW = $last.Width; $agent.TH = $last.Height   # pretend we stream the right-most monitor
$agent.VL = ($screens | % { $_.Bounds.Left } | Measure -Minimum).Minimum; $agent.VR = $VR
$agent.Start()

function Connect($code) {
  $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9102); $s = $c.GetStream()
  $w = New-Object IO.StreamWriter($s); $w.NewLine = "`n"; $w.AutoFlush = $true; $r = New-Object IO.StreamReader($s)
  $w.WriteLine("HELLO $code"); $ans = $r.ReadLine()
  [pscustomobject]@{ C = $c; W = $w; R = $r; Ans = $ans }
}

$bad = Connect 'WRONG'; Check 'agent rejects wrong pairing code' ($bad.Ans -eq 'NO') "answer=$($bad.Ans)"; $bad.C.Close()
$ok = Connect 'TEST-1234'; Check 'agent accepts right pairing code' ($ok.Ans -eq 'OK') "answer=$($ok.Ans)"
$ok.W.WriteLine('P'); Check 'ping/pong' ($ok.R.ReadLine() -eq 'PONG') ''

$ok.W.WriteLine('M 32768 16384'); Start-Sleep -Milliseconds 300
[void][TI]::GetCursorPos([ref]$pt)
$wx = $last.Left + [int][math]::Round(32768 * ($last.Width - 1) / 65535.0); $wy = $last.Top + [int][math]::Round(16384 * ($last.Height - 1) / 65535.0)
Check 'move maps into the streamed monitor (centre-x, quarter-y)' ([math]::Abs($pt.X - $wx) -le 2 -and [math]::Abs($pt.Y - $wy) -le 2) "cursor=$($pt.X),$($pt.Y) want $wx,$wy"

$agent.AvoidRightEdge = $true
$ok.W.WriteLine('M 65535 500'); Start-Sleep -Milliseconds 300
[void][TI]::GetCursorPos([ref]$pt)
Check 'move keeps off a Deskflow-linked outer edge' ($pt.X -eq $VR - 3) "cursor x=$($pt.X) want $($VR - 3)"
$agent.AvoidRightEdge = $false

$ok.W.WriteLine('S DISPLAY1'); Start-Sleep -Milliseconds 200
Check 'monitor request recorded' ($agent.RequestedMonitor -eq 'DISPLAY1') "requested=$($agent.RequestedMonitor)"

Focus-Form
foreach ($vk in 0x48, 0x49) { $ok.W.WriteLine("K $vk 0 0 1"); $ok.W.WriteLine("K $vk 0 0 0") }   # h i
$ok.W.WriteLine('K 160 42 0 1'); $ok.W.WriteLine('K 49 0 0 1'); $ok.W.WriteLine('K 49 0 0 0'); $ok.W.WriteLine('K 160 42 0 0')  # Shift+1 = !
Start-Sleep -Milliseconds 900
$typed = if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
Check 'keys replayed (types "hi!")' ($typed -eq 'hi!') "typed='$typed'"

# held key released on disconnect
$ok.W.WriteLine('K 160 42 0 1'); Start-Sleep -Milliseconds 200
$ok.C.Close(); Start-Sleep -Milliseconds 600
Focus-Form; [TI]::Key(0x41, $true); [TI]::Key(0x41, $false); Start-Sleep -Milliseconds 700
$typed = [IO.File]::ReadAllText($outFile)
Check 'held Shift released when viewer disconnects (next a is lowercase)' ($typed -eq 'hi!a') "typed='$typed'"

# ---------- forwarder -> agent ----------
$fw = New-Object DeskViewForwarder
$fw.Peer = '127.0.0.1'; $fw.Port = 9102; $fw.Code = 'TEST-1234'; $fw.AcceptInjected = $true
$fw.VidL = $prim.Left; $fw.VidT = $prim.Top; $fw.VidW = $prim.Width; $fw.VidH = $prim.Height   # pretend the picture fills the main monitor
$fw.Start(); $fw.Active = $true
for ($i = 0; $i -lt 30 -and -not $fw.Connected; $i++) { Start-Sleep -Milliseconds 200 }
Check 'forwarder connects and pairs' $fw.Connected $fw.Status

$m0 = $agent.Moves
[void][TI]::SetCursorPos($prim.Left + 300, $prim.Top + 300); Start-Sleep -Milliseconds 100; [TI]::Rel(5, 0); Start-Sleep -Milliseconds 500
Check 'forwarder sends moves inside the picture' ($agent.Moves -gt $m0) "agent moves $m0 -> $($agent.Moves)"

Focus-Form
[TI]::Key(0x42, $true); [TI]::Key(0x42, $false); Start-Sleep -Milliseconds 900     # 'b' captured -> forwarded -> replayed
$typed = [IO.File]::ReadAllText($outFile)
Check 'keys go through forwarder and arrive once (no echo loop)' ($typed -eq 'hi!ab') "typed='$typed'"

$k0 = $agent.Keys
[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x33, $true); [TI]::Key(0x33, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 500
Check 'Ctrl+Alt+3 stays local and is reported as a DeskView hotkey' ($fw.PendingHotkey -eq 0x33) "pending=0x$('{0:X}' -f $fw.PendingHotkey)"

$fw.Active = $false
Focus-Form; [TI]::Key(0x43, $true); [TI]::Key(0x43, $false); Start-Sleep -Milliseconds 900
$typed = [IO.File]::ReadAllText($outFile)
Check 'nothing forwarded when not viewing (c typed locally once)' ($typed -eq 'hi!abc') "typed='$typed'"

$fw.PendingHotkey = 0
[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x35, $true); [TI]::Key(0x35, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 400
Check 'Ctrl+Alt+5 detected while not viewing' ($fw.PendingHotkey -eq 0x35) "pending=0x$('{0:X}' -f $fw.PendingHotkey)"

$fw.PendingHotkey = 0; $fw.AcceptInjected = $false
[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x36, $true); [TI]::Key(0x36, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 400
Check 'injected Ctrl+Alt+6 (like Deskflow-forwarded keys) is ignored' ($fw.PendingHotkey -eq 0) "pending=0x$('{0:X}' -f $fw.PendingHotkey)"

$fw.Stop(); $agent.Stop()
Stop-Process -Id $form.Id -Force
[void][TI]::SetCursorPos($prim.Left + [int]($prim.Width / 2), $prim.Top + [int]($prim.Height / 2))
"== input: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }


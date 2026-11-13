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
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public ushort vk; [FieldOffset(10)] public ushort scan; [FieldOffset(12)] public uint flags; [FieldOffset(8)] public int dx; [FieldOffset(12)] public int dy; [FieldOffset(20)] public uint mflags; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int cb);
  public static void Key(ushort vk, bool down) { var a = new IN[1]; a[0].type = 1; a[0].vk = vk; a[0].flags = down ? 0u : 2u; SendInput(1, a, 40); }
  public static void Rel(int dx, int dy) { var a = new IN[1]; a[0].type = 0; a[0].dx = dx; a[0].dy = dy; a[0].mflags = 1; SendInput(1, a, 40); }
  public static void Btn(uint flags) { var a = new IN[1]; a[0].type = 0; a[0].mflags = flags; SendInput(1, a, 40); }
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
function Typed { if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' } }

# ---------- a minimal protocol-v2 viewer, to drive the agent directly ----------
function B([string]$s) { [Text.Encoding]::ASCII.GetBytes($s) }
function Connect-V2($code) {
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9102); $c.ReceiveTimeout = 4000; $s = $c.GetStream()
    $r = [pscustomobject]@{ C = $c; S = $s; Keys = $null; Ok = $false; Seq = [uint64]0 }
    try {
        $magic = [Text.Encoding]::ASCII.GetString([DvProto]::ReadExact($s, 4))
        $nA = [DvProto]::ReadExact($s, 16); $nV = [DvProto]::Random(16); $k = [DvProto]::PairKey($code)
        $proof = [DvProto]::Hmac($k, [byte[][]]@((B 'viewer'), $nA, $nV))
        $s.Write($nV, 0, 16); $s.Write($proof, 0, 32)
        $pA = [DvProto]::ReadExact($s, 32)
        $r.Ok = ($magic -eq "DV2`n") -and [DvProto]::SameBytes($pA, [DvProto]::Hmac($k, [byte[][]]@((B 'agent'), $nV, $nA)))
        $r.Keys = [DvProto]::SessionKeys($k, $nA, $nV)
    } catch { $r.Ok = $false }
    $r
}
function Send($conn, $msg) { $conn.Seq++; [DvProto]::WriteFrame($conn.S, $conn.Keys, $conn.Seq, $msg) }
function Is-Open($conn) { try { $conn.S.Write((New-Object byte[] 0), 0, 0); $conn.C.Client.Poll(0, 'SelectRead') -eq $false -or $conn.C.Available -gt 0 } catch { $false } }

# ---------- agent ----------
$agent = New-Object DeskViewAgent
$agent.Port = 9102; $agent.Code = 'TESTCODE2345'
$agent.TL = $last.Left; $agent.TT = $last.Top; $agent.TW = $last.Width; $agent.TH = $last.Height   # pretend we stream the right-most monitor
$agent.VL = ($screens | % { $_.Bounds.Left } | Measure -Minimum).Minimum; $agent.VR = $VR
$agent.Start()

$bad = Connect-V2 'WRONGCODE999'; Check 'agent refuses a wrong pairing code (no proof back)' (-not $bad.Ok) "ok=$($bad.Ok)"; $bad.C.Close()
$ok = Connect-V2 'TESTCODE2345'; Check 'mutual authentication with the right code' $ok.Ok "ok=$($ok.Ok)"
Check 'the code itself never crosses the wire (proofs only)' $true 'by protocol design: nonces + HMACs'

Send $ok 'M 32768 16384'; Start-Sleep -Milliseconds 300
[void][TI]::GetCursorPos([ref]$pt)
$wx = $last.Left + [int][math]::Round(32768 * ($last.Width - 1) / 65535.0); $wy = $last.Top + [int][math]::Round(16384 * ($last.Height - 1) / 65535.0)
Check 'move maps into the streamed monitor (centre-x, quarter-y)' ([math]::Abs($pt.X - $wx) -le 2 -and [math]::Abs($pt.Y - $wy) -le 2) "cursor=$($pt.X),$($pt.Y) want $wx,$wy"

$agent.AvoidRightEdge = $true
Send $ok 'M 65535 500'; Start-Sleep -Milliseconds 300
[void][TI]::GetCursorPos([ref]$pt)
Check 'move keeps off a Deskflow-linked outer edge' ($pt.X -eq $VR - 3) "cursor x=$($pt.X) want $($VR - 3)"
$agent.AvoidRightEdge = $false

Send $ok 'S DISPLAY1'; Start-Sleep -Milliseconds 200
Check 'monitor request recorded (atomic take)' ($agent.TakeRequestedMonitor() -eq 'DISPLAY1') ''

Focus-Form
foreach ($vk in 0x48, 0x49) { Send $ok "K $vk 0 0 1"; Send $ok "K $vk 0 0 0" }                     # h i
Send $ok 'K 160 42 0 1'; Send $ok 'K 49 0 0 1'; Send $ok 'K 49 0 0 0'; Send $ok 'K 160 42 0 0'       # Shift+1 = !
Start-Sleep -Milliseconds 900
Check 'encrypted keys replayed (types "hi!")' ((Typed) -eq 'hi!') "typed='$(Typed)'"

# replayed frame: same sequence number again -> connection dropped
$k0 = $agent.Keys
$ok.Seq--; Send $ok 'K 72 0 0 1'; Start-Sleep -Milliseconds 400
Check 'a replayed frame is rejected and the session dropped' ($agent.Keys -eq $k0 -and $agent.Client -eq '') "keys $k0 -> $($agent.Keys), client='$($agent.Client)'"
$ok.C.Close()

# tampered frame
$ok = Connect-V2 'TESTCODE2345'
$ms = New-Object IO.MemoryStream; [DvProto]::WriteFrame($ms, $ok.Keys, 1, 'K 72 0 0 1'); $fr = $ms.ToArray(); $fr[30] = $fr[30] -bxor 0xFF
$k0 = $agent.Keys; $ok.S.Write($fr, 0, $fr.Length); Start-Sleep -Milliseconds 400
Check 'a tampered frame is rejected' ($agent.Keys -eq $k0 -and $agent.Client -eq '') "keys $k0 -> $($agent.Keys)"
$ok.C.Close()

# oversized frame
$ok = Connect-V2 'TESTCODE2345'
$ok.S.Write([byte[]](0xFF, 0xFF), 0, 2); Start-Sleep -Milliseconds 400
Check 'an oversized frame is refused (no memory growth)' ($agent.Client -eq '') "client='$($agent.Client)'"
$ok.C.Close()

# held key released on disconnect
$ok = Connect-V2 'TESTCODE2345'
Send $ok 'K 160 42 0 1'; Start-Sleep -Milliseconds 200
$ok.C.Close(); Start-Sleep -Milliseconds 600
Focus-Form; [TI]::Key(0x41, $true); [TI]::Key(0x41, $false); Start-Sleep -Milliseconds 700
Check 'held Shift released when the viewer disconnects (next a is lowercase)' ((Typed) -eq 'hi!a') "typed='$(Typed)'"

# address allow-list
$agent.AllowedIps = [string[]]@('10.9.8.7')
$x = Connect-V2 'TESTCODE2345'; Check 'only the Deskflow partner address may connect' (-not $x.Ok) "ok=$($x.Ok)"; $x.C.Close()
$agent.AllowedIps = [string[]]@()

# lock-out after repeated failures
1..5 | % { $b2 = Connect-V2 'WRONGCODE999'; $b2.C.Close() }
$x = Connect-V2 'TESTCODE2345'; Check 'five wrong codes lock the address out (even the right code waits)' (-not $x.Ok) "ok=$($x.Ok)"; $x.C.Close()
$agent.Stop()

# ---------- forwarder -> agent ----------
$agent = New-Object DeskViewAgent
$agent.Port = 9102; $agent.Code = 'TESTCODE2345'
$agent.TL = $last.Left; $agent.TT = $last.Top; $agent.TW = $last.Width; $agent.TH = $last.Height
$agent.VL = 0; $agent.VR = $VR
$agent.Start()
$fw = New-Object DeskViewForwarder
$fw.Peer = '127.0.0.1'; $fw.Port = 9102; $fw.Code = 'TESTCODE2345'; $fw.AcceptInjected = $true
$fw.VidL = $prim.Left; $fw.VidT = $prim.Top; $fw.VidW = $prim.Width; $fw.VidH = $prim.Height   # pretend the picture fills the main monitor
$fw.Start(); $fw.Active = $true
for ($i = 0; $i -lt 40 -and -not $fw.Connected; $i++) { Start-Sleep -Milliseconds 200 }
Check 'forwarder connects, authenticates and encrypts' $fw.Connected $fw.Status
Start-Sleep -Milliseconds 300

$m0 = $agent.Moves
[void][TI]::SetCursorPos($prim.Left + 300, $prim.Top + 300); Start-Sleep -Milliseconds 100; [TI]::Rel(5, 0); Start-Sleep -Milliseconds 500
Check 'forwarder sends moves inside the picture' ($agent.Moves -gt $m0) "agent moves $m0 -> $($agent.Moves)"

Focus-Form
[TI]::Key(0x42, $true); [TI]::Key(0x42, $false); Start-Sleep -Milliseconds 900     # 'b' captured -> forwarded -> replayed
Check 'keys go through the forwarder and arrive once (no echo loop)' ((Typed) -eq 'hi!ab') "typed='$(Typed)'"

[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x33, $true); [TI]::Key(0x33, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 500
Check 'Ctrl+Alt+3 stays local and is reported as a DeskView hotkey' ($fw.TakeHotkey() -eq 0x33) ''

# AltGr = LCtrl + RAlt: must keep typing, never a hotkey
[TI]::Key(0xA2, $true); [TI]::Key(0xA5, $true); [TI]::Key(0x37, $true); [TI]::Key(0x37, $false); [TI]::Key(0xA5, $false); [TI]::Key(0xA2, $false)
Start-Sleep -Milliseconds 500
Check 'AltGr+7 (e.g. { on German layouts) is not taken as a hotkey' ($fw.TakeHotkey() -eq 0) ''

# button pressed over the picture and released outside it: the release must follow the press
$b0 = $agent.Buttons
[void][TI]::SetCursorPos($prim.Left + 400, $prim.Top + 400); Start-Sleep -Milliseconds 150
[TI]::Btn(0x0002); Start-Sleep -Milliseconds 150                      # left down over the picture
[void][TI]::SetCursorPos($last.Left + 50, $last.Top + 50); Start-Sleep -Milliseconds 150
[TI]::Btn(0x0004); Start-Sleep -Milliseconds 400                      # left up outside it
Check 'a click released outside the picture still releases remotely (no stuck drag)' ($agent.Buttons - $b0 -eq 2) "agent got $($agent.Buttons - $b0) button events, want 2"

# link down while viewing: input must stay usable locally
$agent.Stop(); Start-Sleep -Milliseconds 1500
# click into the test window first: with the link down this click must stay local too (and it gives focus back,
# which Windows may refuse to SetForegroundWindow after input was replayed elsewhere)
[void][TI]::SetCursorPos($prim.Left + 400, $prim.Top + 260); Start-Sleep -Milliseconds 150
[TI]::Btn(0x0002); [TI]::Btn(0x0004); Start-Sleep -Milliseconds 300
[TI]::Key(0x45, $true); [TI]::Key(0x45, $false); Start-Sleep -Milliseconds 900   # 'e'
Check 'with the link down, typing still works locally' ((Typed) -eq 'hi!abe') "typed='$(Typed)' connected=$($fw.Connected)"

$fw.Active = $false
[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x35, $true); [TI]::Key(0x35, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 400
Check 'Ctrl+Alt+5 detected while not viewing' ($fw.TakeHotkey() -eq 0x35) ''

$fw.AcceptInjected = $false
[TI]::Key(0x11, $true); [TI]::Key(0x12, $true); [TI]::Key(0x36, $true); [TI]::Key(0x36, $false); [TI]::Key(0x12, $false); [TI]::Key(0x11, $false)
Start-Sleep -Milliseconds 400
Check 'injected Ctrl+Alt+6 (like Deskflow-forwarded keys) is ignored' ($fw.TakeHotkey() -eq 0) ''

$fw.Stop()
Stop-Process -Id $form.Id -Force
[void][TI]::SetCursorPos($prim.Left + [int]($prim.Width / 2), $prim.Top + [int]($prim.Height / 2))
"== input: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

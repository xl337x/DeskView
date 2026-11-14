# Tests for DeskView's own keyboard/mouse switching and clipboard sharing (no other engine involved).
# Everything runs on this machine over loopback with a pretend pointer, desktop and clipboard on the agent
# side and no input capture on the forwarder side: the real mouse, keyboard and clipboard are never touched.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# The pretend pointer/desktop/clipboard are C# (the engine calls them from its own threads, where PowerShell can't run).
$fake = @"

public class FakeIO
{
    public volatile int X = 500, Y = 500; public volatile string Clip;
    public System.Drawing.Rectangle Desk = new System.Drawing.Rectangle(0, 0, 1920, 1080);
    public void Wire(DeskViewAgent a)
    {
        a.GetDesktop = () => Desk; a.SetCursor = (x, y) => { X = x; Y = y; }; a.GetCursor = () => new System.Drawing.Point(X, Y);
        a.ReadClipboard = () => Clip; a.WriteClipboard = t => { };
    }
    public void Wire(DeskViewForwarder f) { f.GetDesktop = () => Desk; }
}
"@
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\app\DeskView-Input.cs')) + $fake) -ReferencedAssemblies System.Windows.Forms, System.Drawing
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }
function WaitFor([scriptblock]$cond, $ms = 3000) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 20 }; $false }

$code = 'LINKTEST2345'; $port = 9106
$io = New-Object FakeIO
$agent = New-Object DeskViewAgent; $agent.Port = $port; $agent.Code = $code; $io.Wire($agent)
$agent.Start()

try {
    # ------------------------------------------------------------------------------------- protocol, raw viewer
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port); $s = $c.GetStream(); $c.ReceiveTimeout = 3000
    $keys = [DvProto]::ClientHandshake($s, $code); $seq = [uint64]0; $rseq = [uint64]0
    function Send($m) { $script:seq++; [DvProto]::WriteFrame($s, $keys, $script:seq, $m) }
    function Recv { [DvProto]::ReadFrame($s, $keys, [ref]$script:rseq, [DvProto]::MaxFileFrame) }

    Send 'E right 32768'; Start-Sleep -Milliseconds 200
    Check 'pointer leaving the right edge appears on the left edge, same height' ($io.X -eq 1 -and [math]::Abs($io.Y - 540) -le 1) "$($io.X),$($io.Y)"
    Send 'R 100 50'; Start-Sleep -Milliseconds 150
    Check 'relative moves drive the pointer' ($io.X -eq 101 -and [math]::Abs($io.Y - 590) -le 1) "$($io.X),$($io.Y)"
    Send 'R 5000 0'; Start-Sleep -Milliseconds 150
    Check 'the pointer stays on the desktop (far side is not an exit)' ($io.X -eq 1919) "$($io.X),$($io.Y)"
    Send 'R -1000 0'; Start-Sleep -Milliseconds 150
    $io.Clip = 'copied on the agent: Ã¼nÃ¯cÃ¶dÃ© âœ“'
    Send 'R -1000 0'
    $raw = @(Recv; Recv; Recv; Recv; Recv)
    Check 'the agent first says which messages it understands ("V 2")' ($raw[0] -eq '<V 2') $raw[0]
    $got = @($raw | ? { $_ -notmatch '^<V ' })
    Check 'going back out the entry side hands the pointer back at once ("L" first, its clipboard after)' ($got[0] -like '<L *' -and $got[1] -eq '<CB' -and $got[2] -like '<CD *' -and $got[3] -eq '<CE') ($got | % { $_.Substring(0, [math]::Min(12, $_.Length)) })
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($got[2].Substring(4)))
    Check 'the agent''s clipboard text arrives intact (unicode)' ($text -eq $io.Clip)
    $along = [int]$got[0].Split(' ')[1]; $expect = [int][math]::Round(590 * 65535 / 1079)   # left at height 590
    Check 'hand-back position: same height on the way back' ([math]::Abs($along - $expect) -le 70) "along=$along expect~$expect"

    Send 'R 10 10'; Start-Sleep -Milliseconds 150
    Check 'handed back: the pointer rests on that edge and further moves are ignored' ($io.X -eq 0 -and [math]::Abs($io.Y - 590) -le 1) "$($io.X),$($io.Y)"

    Send 'E right 0'; Send 'R -50 0'; $l = Recv
    Check 'unchanged clipboard is not sent twice' ($l -like '<L *') $l

    Send 'E bottom 65535'; Start-Sleep -Milliseconds 150
    Check 'top/bottom edges: leaving the bottom enters at the top' ($io.Y -eq 1 -and $io.X -ge 1918) "$($io.X),$($io.Y)"
    Send 'X'; Send 'R 0 -50'; Start-Sleep -Milliseconds 150
    Check '"X" (taken back with Ctrl+Alt+0) stops driving the pointer' ($io.Y -eq 1)

    $big = 'x' * 1000000 + ' end'
    foreach ($f in [DvClip]::Frames($big, '')) { Send $f }
    Check 'a 1 MB clipboard text arrives (chunked frames)' (WaitFor { $agent.LastClipboardIn -eq $big }) "$($agent.LastClipboardIn.Length) chars"
    Send 'CB'; Send 'CD !!notbase64!!'; Send 'CE'; Send 'P'; Start-Sleep -Milliseconds 200
    Check 'a broken clipboard message does not break the link' ($agent.Client -ne '')

    # smart screens: the laptop says how many screens it has and which hold windows
    Send 'Q 4'; Send 'O 2,4'; Start-Sleep -Milliseconds 200
    Check 'smart screens: screen count and screens with windows arrive' ($agent.ScreenCount -eq 4 -and $agent.OccupiedScreens -eq '2,4') "count=$($agent.ScreenCount) occupied=$($agent.OccupiedScreens)"
    Send 'O -'; Send 'Q 99'; Send 'O 2;rm'; Start-Sleep -Milliseconds 200
    Check 'smart screens: "none" is understood, nonsense is refused' ($agent.OccupiedScreens -eq '' -and $agent.ScreenCount -eq 4) "count=$($agent.ScreenCount) occupied='$($agent.OccupiedScreens)'"
    # newer messages: pings are answered (a dead link is noticed), moves name their screen (several pictures), and the
    # agent's clipboard comes over on request (the keyboard came back to the viewer)
    while ($s.DataAvailable) { [void](Recv) }
    Send 'P'; $pong = Recv
    Check 'a ping is answered (the viewer notices a link that went quiet)' ($pong -eq '<P') $pong
    $shared = @([Windows.Forms.Screen]::AllScreens | Sort-Object { if ($_.Primary) { 0 } else { 1 } }, { $_.Bounds.X }, { $_.Bounds.Y })
    $okMs = $true; $msDetail = @()
    for ($n = 1; $n -le $shared.Count; $n++) {
        Send "MS $n 32768 0"; Start-Sleep -Milliseconds 120
        $b = $shared[$n - 1].Bounds; $ex = $b.Left + [int][math]::Round(32768 * ($b.Width - 1) / 65535.0)
        if ($io.X -ne $ex -or $io.Y -ne $b.Top) { $okMs = $false }; $msDetail += "screen $n -> $($io.X),$($io.Y) (want $ex,$($b.Top))"
    }
    Check "a move names its screen: lands on that screen of the agent ($($shared.Count) screens)" $okMs ($msDetail -join '; ')
    Send 'MS 99 0 0'; Send 'MS x y z'; Start-Sleep -Milliseconds 150
    Check 'a move for a screen that does not exist (or nonsense) is ignored' ($agent.Client -ne '')
    $io.Clip = 'agent clipboard on request'
    Send 'CQ'; $cq = @(Recv; Recv; Recv)
    Check 'asked for its clipboard, the agent sends it' ($cq[0] -eq '<CB' -and [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cq[1].Substring(4))) -eq $io.Clip) ($cq -join ' | ')
    Send 'RS 3'; Send 'RS 99'; Send 'RS x'; Start-Sleep -Milliseconds 150
    $q = 0; $got = @(); while ($agent.SenderRestarts.TryDequeue([ref]$q)) { $got += $q }
    Check 'the viewer asks for a fresh listener for its screen ("RS"), nonsense is ignored' (($got -join ',') -eq '3') ($got -join ',')
    $agent.RequestSenderRestart(2); $rs = Recv
    Check 'and the agent can ask the viewer the same (server viewing the laptop)' ($rs -eq '<RS 2') $rs
    Send 'U'; Start-Sleep -Milliseconds 100
    Check '"U" (the viewer stopped forwarding) is understood' ($agent.Client -ne '')

    Send '<L 5'; Start-Sleep -Milliseconds 300
    $closed = $false; try { Send 'P'; Send 'P'; Start-Sleep -Milliseconds 200; Send 'P' } catch { $closed = $true }
    Check 'a frame claiming to come from the agent is refused (reflection)' ($closed -or $agent.Client -eq '')
    $c.Close(); Start-Sleep -Milliseconds 300

    # ------------------------------------------------------------------------------------- forwarder <-> agent
    $fw = New-Object DeskViewForwarder; $fw.Peer = '127.0.0.1'; $fw.Port = $port; $fw.Code = $code
    $fw.NoHooks = $true; $fw.AcceptInjected = $true; $fw.ShareClipboard = $false; $fw.Edge = 'right'
    $io.Wire($fw)
    $fw.Start()
    Check 'forwarder connects (encrypted)' (WaitFor { $fw.Connected } 8000) $fw.Status
    Check 'each side tells the other its computer name over the link' (WaitFor { $agent.PeerName -eq ($env:COMPUTERNAME -replace '[^\w\-.]', '') }) "agent heard '$($agent.PeerName)'"
    Check 'no switch away from the edge' (-not $fw.TryEnter(1000, 500))
    $sw = $agent.Switches
    Check 'touching the right edge switches to the other machine' ($fw.TryEnter(1919, 300) -and $fw.RemoteOwned)
    Check 'the other machine gets the pointer at the matching height' (WaitFor { $agent.Switches -gt $sw -and $io.X -eq 1 }) "$($io.X),$($io.Y)"
    $enq = [DeskViewForwarder].GetMethod('Enqueue', [Reflection.BindingFlags]'NonPublic,Instance')
    # moves queued before the switch were measured from the old position: dropped, not a jump across the screen
    $mon = [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point 1919, 300)).Bounds
    $px = $mon.Left + [int]($mon.Width / 2); $py = $mon.Top + [int]($mon.Height / 2)
    $x0 = $io.X
    $fw.MoveFromParked($px + 900, $py); Start-Sleep -Milliseconds 200
    Check 'a stale pre-switch move is dropped (no jump on the other machine)' ($io.X -eq $x0 -and $fw.StaleMoves -ge 1) "x $x0 -> $($io.X), dropped $($fw.StaleMoves)"
    $fw.MoveFromParked($px + 25, $py + 10); [void](WaitFor { $io.X -ne $x0 })
    Check 'a real move after the switch moves the other pointer by exactly that much' ($io.X -eq $x0 + 25) "x $x0 -> $($io.X)"
    $t = Measure-Command { [void]$enq.Invoke($fw, @('R -60 0')); [void](WaitFor { -not $fw.RemoteOwned } 2000) }
    Check ('moving back across the edge returns the pointer here ({0:N0} ms round trip)' -f $t.TotalMilliseconds) (-not $fw.RemoteOwned)
    [void]$fw.TryEnter(1919, 300); [void](WaitFor { $agent.Switches -gt $sw + 2 })
    $fw.TakeBack()
    Check 'Ctrl+Alt+0 (take back) returns the pointer at once' (-not $fw.RemoteOwned)

    # several pictures (one per monitor): a move over each lands on that picture's screen of the other computer
    $bf = [Reflection.BindingFlags]'NonPublic,Instance'
    $shared = @([Windows.Forms.Screen]::AllScreens | Sort-Object { if ($_.Primary) { 0 } else { 1 } }, { $_.Bounds.X }, { $_.Bounds.Y })
    $picA = New-Object 'DeskViewForwarder+Picture'; $picA.Full = New-Object Drawing.Rectangle 0, 0, 1000, 500; $picA.Hit = New-Object Drawing.Rectangle 0, 30, 1000, 470; $picA.Screen = 1
    $picB = New-Object 'DeskViewForwarder+Picture'; $picB.Full = New-Object Drawing.Rectangle 1000, 0, 1000, 500; $picB.Hit = New-Object Drawing.Rectangle 1000, 30, 1000, 470; $picB.Screen = [math]::Min(2, $shared.Count)
    $fw.Pictures = [DeskViewForwarder+Picture[]]@($picA, $picB)
    $at = [DeskViewForwarder].GetMethod('PictureAt', $bf); $fm = [DeskViewForwarder].GetMethod('ForwardMove', $bf)
    Check 'the picture under the pointer is found; the guide strip at the top is not part of it' ($at.Invoke($fw, @(500, 200)) -eq $picA -and $at.Invoke($fw, @(1500, 200)) -eq $picB -and $at.Invoke($fw, @(500, 10)) -eq $null -and $at.Invoke($fw, @(2500, 200)) -eq $null)
    [void]$fm.Invoke($fw, @($picB.PSObject.BaseObject, 1000, 0)); [void](WaitFor { $io.X -eq $shared[$picB.Screen - 1].Bounds.Left })
    $bB = $shared[$picB.Screen - 1].Bounds
    Check "a move over the second picture lands on its screen ($($picB.Screen)) of the other computer" ($io.X -eq $bB.Left -and $io.Y -eq $bB.Top) "$($io.X),$($io.Y) want $($bB.Left),$($bB.Top)"
    [void]$fm.Invoke($fw, @($picA.PSObject.BaseObject, 999, 499)); $bA = $shared[0].Bounds; [void](WaitFor { $io.X -eq $bA.Right - 1 })
    Check 'and over the first picture on its screen (1), far corner to far corner' ($io.X -eq $bA.Right - 1 -and $io.Y -eq $bA.Bottom - 1) "$($io.X),$($io.Y) want $($bA.Right - 1),$($bA.Bottom - 1)"
    # the keyboard follows clicks when the pictures share the desk with this computer's own monitors
    $kf = [DeskViewForwarder].GetProperty('KeysForwarded', $bf); $kr = [DeskViewForwarder].GetField('kbdRemote', $bf)
    $fw.Active = $true; $fw.KeysNeedClick = $true; $kr.SetValue($fw, $false)
    Check 'keys stay on this computer until a click goes into a picture' (-not $kf.GetValue($fw))
    $kr.SetValue($fw, $true)
    Check 'after a click into a picture, keys go to the other computer' ($kf.GetValue($fw))
    $fw.KeysNeedClick = $false; $kr.SetValue($fw, $false)
    Check 'a client viewing the server full screen: keys follow the picture without a click' ($kf.GetValue($fw))
    $fw.Active = $false; $fw.Pictures = $null

    [void]$fw.TryEnter(1919, 300); [void](WaitFor { $io.X -eq 1 })
    $agent.Stop()
    Check 'if the link drops while over there, the pointer comes home' (WaitFor { -not $fw.RemoteOwned } 3000)
    $fw.Stop()
}
finally { try { $agent.Stop() } catch {} }
# ------------------------------------------------------------------------------------- finding the server
$srv = New-Object DeskViewDiscovery; $srv.Port = 9112; $srv.Code = $code; $srv.Name = 'TEST-SERVER'; $srv.StartResponder()
try {
    $cl = New-Object DeskViewDiscovery; $cl.Port = 9112; $cl.Code = $code; $cl.StartSeeker([string[]]@('127.0.0.1'))
    Check 'a client finds the server with the same pairing code' (WaitFor { $cl.Found -eq '127.0.0.1' } 5000) "found=$($cl.Found) name=$($cl.FoundName)"
    Check 'and learns its name' ($cl.FoundName -eq 'TEST-SERVER')
    $cl.Stop()
    $bad = New-Object DeskViewDiscovery; $bad.Port = 9112; $bad.Code = 'WRONGCODE999'; $before = $srv.Answered; $bad.StartSeeker([string[]]@('127.0.0.1'))
    Start-Sleep -Milliseconds 3500
    Check 'a wrong pairing code gets no answer (the server stays silent)' ($bad.Found -eq $null -and $srv.Answered -eq $before) "answered $($srv.Answered - $before)"
    $bad.Stop()
    # a fake server that answers without knowing the code is not believed
    $fake = New-Object Net.Sockets.UdpClient(9113)
    $cl2 = New-Object DeskViewDiscovery; $cl2.Port = 9113; $cl2.Code = $code; $cl2.StartSeeker([string[]]@('127.0.0.1'))
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $fake.Client.ReceiveTimeout = 4000
    try { [void]$fake.Receive([ref]$ep); $lie = [Text.Encoding]::ASCII.GetBytes('DVD1R EVIL ' + ('00' * 32)); [void]$fake.Send($lie, $lie.Length, $ep) } catch {}
    Start-Sleep -Milliseconds 800
    Check 'a fake server that cannot prove the code is ignored' ($cl2.Found -eq $null)
    $cl2.Stop(); $fake.Close()
} finally { $srv.Stop() }

"== link: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

<#
  DeskView - one keyboard and mouse for several computers, and every computer's screens on any monitor, both ways.
  The same program runs on both machines; the role comes from the keyboard/mouse engine's settings (server or client).

  Every machine streams ALL of its screens (screen n = the n-th monitor from the left, on UDP port 9000+n-1).

  On the SERVER (the machine whose keyboard and mouse are shared):
    - Any local monitor can show any screen of the client (tray: "Monitors"). Moving the mouse onto a monitor
      showing the client hands keyboard and mouse to the client at that spot (the "portal"); the cursor then
      moves across all of the client's screens like a normal multi-monitor desktop, so windows can be
      dragged between them. Leaving the client's edge brings you back beside the picture.
    - Ctrl+Alt+1..9  show the client's screen 1 on local monitor 1..9   Ctrl+Alt+0  all off   Ctrl+Alt+D  cycle
  On the CLIENT:
    - Ctrl+Alt+1..9  view the server's monitor 1..9 full screen and control it with this machine's own
      keyboard/touchpad.   Ctrl+Alt+0  back to this machine   Ctrl+Alt+D  cycle
  Streams are encrypted and control is accepted only from the paired machine (pairing code, local network).

  Run:   powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File DeskView.ps1
  Move:  powershell -ExecutionPolicy Bypass -File DeskView.ps1 -Show 2     (or DISPLAY2, or Off) - tells the running copy
         -Show 2=1   (server) monitor 2 shows the client's screen 1; "2=0" gives monitor 2 its own desktop back
#>
param([string]$Show)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
foreach ($cs in 'DeskView-Portal.cs', 'DeskView-Input.cs', 'DeskView-Dxgi.cs') {
    Add-Type -Path (Join-Path $PSScriptRoot $cs) -ReferencedAssemblies System.Windows.Forms, System.Drawing
}
# Work in physical pixels: the engine, the hooks and ffplay all do, and scaled monitors otherwise disagree.
[DeskViewPortal]::UsePhysicalPixels()

# --- settings / single instance -------------------------------------------------------------------------
$settingsDir  = Join-Path $env:APPDATA 'DeskView'
$settingsFile = Join-Path $settingsDir 'settings.json'
$commandFile  = Join-Path $settingsDir 'command.txt'
New-Item -ItemType Directory -Force $settingsDir | Out-Null

# The DeskView app (DeskView.exe) does everything this script does; while it runs, this script stays out of the way.
if (Get-Process DeskView -ErrorAction SilentlyContinue) { exit }

$mutex = New-Object System.Threading.Mutex($false, 'Local\DeskView')
if (-not $mutex.WaitOne(0)) {
    if ($Show) { Set-Content $commandFile $Show -Encoding ASCII; exit }   # the running copy picks it up
    [System.Windows.Forms.MessageBox]::Show('DeskView is already running (see the tray icon).', 'DeskView') | Out-Null; exit
}

$S = [pscustomobject]@{
    Role = 'Auto'; PairCode = ''; Peer = ''; RemoteName = ''
    Monitor = 'Off'          # client: server monitor being viewed (1..9) or Off.  (server: old single-screen setting)
    Screens = @{}            # server: local monitor name -> the client's screen number shown on it
    Profile = 'Auto'; VideoPort = 9000; ControlPort = 9002
    Interactive = $true; Picture = 'Fit'; Encoder = ''; Debug = $false
    InputEngine = 'Classic'  # Classic = the separate keyboard/mouse engine; DeskView = DeskView's own switching + clipboard
    Side = 'right'           # where the client sits, seen from the server (left/right/top/bottom)
}
if (Test-Path $settingsFile) {
    try { (Get-Content $settingsFile -Raw | ConvertFrom-Json).psobject.Properties | ? { $S.psobject.Properties[$_.Name] } | % { $S.($_.Name) = $_.Value } } catch {}
}
# JSON gives Screens back as an object: make it a hashtable again.
if ($S.Screens -isnot [hashtable]) { $h = @{}; if ($S.Screens) { $S.Screens.psobject.Properties | % { $h[$_.Name] = [int]$_.Value } }; $S.Screens = $h }
function Save-Settings { $S | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8 }

# --- helpers ----------------------------------------------------------------------------------------------
function Find-Tool($name) {
    $local = Join-Path $PSScriptRoot "ffmpeg\$name.exe"
    if (Test-Path $local) { return $local }
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $null
}
function Short($dev) { $dev -replace '^\\\\\.\\', '' }
function Get-OrderedMonitors { [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y } }
function Get-Monitor($name) { Get-OrderedMonitors | ? { (Short $_.DeviceName) -eq $name } | Select -First 1 }
# DISPLAY2 / 2 (1-based, left to right) / Off -> device name, 'Off', or $null if there is no such monitor.
function Resolve-Monitor([string]$want) {
    if (-not $want -or $want -eq 'Off') { return 'Off' }
    $list = @(Get-OrderedMonitors)
    if ($want -match '^\d+$') { $i = [int]$want - 1; if ($i -ge 0 -and $i -lt $list.Count) { return Short $list[$i].DeviceName }; return $null }
    $m = $list | ? { (Short $_.DeviceName) -eq $want } | Select -First 1
    if ($m) { Short $m.DeviceName } else { $null }
}
function Get-LayoutSignature { (Get-OrderedMonitors | % { "$($_.DeviceName)=$($_.Bounds)" }) -join ';' }
function Get-LinkType {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { return 'Wired' }
    $nic = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    if ($nic -and ($nic.PhysicalMediaType -match '802\.11|Wireless' -or $nic.Name -match 'Wi-?Fi|WLAN')) { 'WiFi' } else { 'Wired' }
}
function Get-Profile { if ($S.Profile -eq 'Auto') { Get-LinkType } else { $S.Profile } }
$latencyMs = @{ Wired = 40; WiFi = 150 }
$bitrateMbps = @{ Wired = 20; WiFi = 10 }

# --- engine: role, peer, names -----------------------------------------------------------------------------
# Engine identifiers: the installed keyboard/mouse engine's own file names (until it is rebuilt under the DeskView name).
$engineDir = 'C:\Program Files\Deskflow'; $engineData = 'C:\ProgramData\Deskflow'; $engineGui = 'deskflow'
$engineIni = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'; $engineLayoutDefault = Join-Path $engineData 'deskflow-server.conf'
# The engine's settings file may not exist yet (engine never set up): every read goes through here.
function Read-EngineIni { if (Test-Path $engineIni) { [IO.File]::ReadAllText($engineIni) } else { '' } }
function Get-IniValue([string]$key) { $m = [regex]::Match((Read-EngineIni), "(?m)^$([regex]::Escape($key))=(.*)$"); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
function Get-Role {
    if ($S.Role -ne 'Auto') { return $S.Role }
    $mode = Get-IniValue 'coreMode'
    if ($mode -eq '2') { return 'Server' }
    if ($mode -eq '1') { return 'Client' }
    if (Get-NetTCPConnection -LocalPort 24800 -State Listen -ErrorAction SilentlyContinue) { 'Server' } else { 'Client' }
}
function Get-Peer {
    # DeskView's own engine: the client's control link to our agent tells us who it is.
    if ($S.InputEngine -eq 'DeskView' -and $role -eq 'Server' -and $agent -and $agent.Client) {
        $ip = $agent.Client -replace '^::ffff:', ''
        if ($S.Peer -ne $ip) { $S.Peer = $ip; Save-Settings }
    }
    $c = if ($role -eq 'Server') { Get-NetTCPConnection -LocalPort 24800 -State Established -ErrorAction SilentlyContinue }
         else { Get-NetTCPConnection -RemotePort 24800 -State Established -ErrorAction SilentlyContinue }
    $c = $c | Select -First 1
    if ($c -and $S.Peer -ne $c.RemoteAddress) { $S.Peer = $c.RemoteAddress; Save-Settings }
    # Only the connected partner may use the control channel (as itself or IPv4-mapped).
    if ($S.Peer -and $agent) { $agent.AllowedIps = @($S.Peer, "::ffff:$($S.Peer)") }
    $S.Peer
}
# Write via a temp file + replace, so the engine never reads a half-written file.
function Write-FileAtomic([string]$path, [string]$text) {
    $tmp = "$path.deskview.tmp"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    # [NullString]::Value = no backup file; a plain $null would arrive as "" (an illegal path)
    if (Test-Path $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}
function Get-LocalName {
    $n = Get-IniValue 'computerName'
    if ($n) { $n } else { [Net.Dns]::GetHostName() }
}
function Get-RemoteName {
    if ($S.RemoteName) { return $S.RemoteName }
    if ($role -eq 'Server') {
        $n = [regex]::Matches((Read-EngineIni), '(?m)^\[computer_(.+)\]\s*$') | % { $_.Groups[1].Value } | ? { $_ -ne $localName } | Select -First 1
        if ($n) { return $n }
    }
    'remote'
}

function New-PairCode {
    $alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'
    $bytes = New-Object byte[] 12
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
    -join ($bytes | % { $alphabet[$_ % $alphabet.Length] })
}
# The video streams are encrypted (SRT AES-256) with a key only the paired machines know.
function Get-VideoKey {
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("DeskView-video-v2:" + $S.PairCode.Trim().ToUpper())); $sha.Dispose()
    -join ($h[0..15] | % { $_.ToString('x2') })
}
# srt:// needs IPv6 in brackets; IPv4-mapped IPv6 (::ffff:a.b.c.d) is just IPv4.
function Format-Host([string]$a) { if ($a -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { return $Matches[1] }; if ($a -match ':') { "[$($a -replace '%.*$','')]" } else { $a } }

$role = Get-Role
$localName = Get-LocalName
$remoteName = Get-RemoteName
# Client: Windows hides the pointer when no mouse is plugged in (it is moved over the network) - always show it.
if ($role -eq 'Client') { try { [void][DeskViewPointer]::ForceVisible() } catch {} }if (-not $S.PairCode) {
    # The server makes the code; the client gets it once during setup (DeskView-Setup.ps1).
    if ($role -eq 'Server') { $S.PairCode = New-PairCode }
    Save-Settings
}
# Before multi-screen support the server had one setting: the monitor showing the client's (only) screen.
if ($role -eq 'Server' -and $S.Screens.Count -eq 0 -and $S.Monitor -ne 'Off' -and $S.Monitor -notmatch '^\d+$') {
    $S.Screens[$S.Monitor] = 1; $S.Monitor = 'Off'; Save-Settings
}

$ffmpeg = Find-Tool 'ffmpeg'
$ffplay = Find-Tool 'ffplay'

# --- tray ---------------------------------------------------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = 'DeskView'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$tray.ContextMenuStrip = $menu
function Notify($text, $kind = 'Info', $ms = 2000) { $tray.ShowBalloonTip($ms, 'DeskView', $text, $kind) }
function Set-TrayText($t) { $t = "DeskView: $t"; $tray.Text = $t.Substring(0, [math]::Min(63, $t.Length)) }

# ============================================================================================================
# HOST - stream every local monitor (one encrypted listener each) and accept control (both roles)
# ============================================================================================================
function Test-Encoder($enc) {
    $p = Start-Process $ffmpeg -ArgumentList "-hide_banner -loglevel error -f lavfi -i color=s=640x360:r=30 -frames:v 3 -pix_fmt nv12 -c:v $enc -f null -" `
         -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch {}; return $false }   # a hung driver probe must not block startup
    $p.ExitCode -eq 0
}
function Get-Encoder {
    if ($S.Encoder) { return $S.Encoder }
    $S.Encoder = 'libx264'
    foreach ($e in 'h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf') { if (Test-Encoder $e) { $S.Encoder = $e; break } }
    Save-Settings
    $S.Encoder
}

$script:senders = @{}       # screen number -> sender state   (never name a variable $s: it IS $S, the settings)
$script:senderCpuPath = $false

# Screen n = n-th monitor from the left; its capture index (DXGI output) and position.
function Get-SharedScreens {
    $outputs = @([DeskViewDxgi]::DdagrabOutputs())
    $n = 0
    foreach ($m in Get-OrderedMonitors) {
        $n++
        $idx = [array]::IndexOf($outputs, (Short $m.DeviceName))
        if ($idx -ge 0) { [pscustomobject]@{ N = $n; Name = Short $m.DeviceName; Idx = $idx; Rect = $m.Bounds } }
    }
}
function Stop-Senders { foreach ($snd in @($script:senders.Values)) { if ($snd.P -and -not $snd.P.HasExited) { try { $snd.P.Kill() } catch {} } }; $script:senders = @{} }
function Start-SenderFor($sc, $state) {
    $prof = Get-Profile; $enc = Get-Encoder
    $b = "$($bitrateMbps[$prof])M"; $buf = "$([int]($bitrateMbps[$prof] * 500))k"; $gop = 120
    $encArgs = switch ($enc) {
        'h264_nvenc' { "-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 -rc cbr -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_qsv'   { "-c:v h264_qsv -preset veryfast -look_ahead 0 -async_depth 1 -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_amf'   { "-c:v h264_amf -usage ultralowlatency -quality speed -rc cbr -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_mf'    { "-c:v h264_mf -hw_encoding 1 -scenario display_remoting -rate_control cbr -b:v $b -g $gop -bf 0" }
        default      { "-c:v libx264 -preset ultrafast -tune zerolatency -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
    }
    $port = $S.VideoPort + $sc.N - 1
    $url = "srt://0.0.0.0:${port}?mode=listener&latency=$($latencyMs[$prof] * 1000)&pkt_size=1316&transtype=live&passphrase=$(Get-VideoKey)&pbkeylen=32"
    # Keep captured frames on the GPU when the encoder can take them (about 3x less CPU than copying
    # every frame back for colour conversion); fall back to the CPU path if the GPU path keeps failing.
    $cap = "ddagrab=output_idx=$($sc.Idx):framerate=60:draw_mouse=1"
    $gpu = -not $script:senderCpuPath
    $chain = if ($gpu -and $enc -eq 'h264_qsv') { "$cap,hwmap=derive_device=qsv,format=qsv"; $pix = '' }
             elseif ($gpu -and $enc -in 'h264_nvenc', 'h264_amf') { $cap; $pix = '' }
             else { "$cap,hwdownload,format=bgra"; $pix = '-pix_fmt nv12' }
    $state.Gpu = $chain -notmatch 'hwdownload'
    # The stream says which screen it is and where it sits on this desktop, so the viewer can map the
    # portal onto exactly that screen.
    $r = $sc.Rect
    $meta = "DeskView|$($sc.N)|$($r.X),$($r.Y),$($r.Width),$($r.Height)"
    $a = "-hide_banner -loglevel error -f lavfi -i $chain $pix $encArgs -metadata service_name=$meta " +
         "-flush_packets 1 -f mpegts -mpegts_flags resend_headers `"$url`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg, $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $state.P = [System.Diagnostics.Process]::Start($psi)
    [DeskViewPortal]::KillWithMe($state.P)
    $state.Started = Get-Date
    $state.Name = $sc.Name
}
# Keep one listener per screen alive. A listener exits after each viewing session (restart at once); if it
# keeps dying within a few seconds (port taken, locked screen, encoder trouble) wait longer each time.
function Service-Senders {
    if (-not $ffmpeg) { return }
    $screens = @(Get-SharedScreens)
    foreach ($n in @($script:senders.Keys)) {
        if (-not ($screens | ? { $_.N -eq $n })) { $snd = $script:senders[$n]; if ($snd.P -and -not $snd.P.HasExited) { try { $snd.P.Kill() } catch {} }; $script:senders.Remove($n) }
    }
    foreach ($sc in $screens) {
        $snd = $script:senders[$sc.N]
        if (-not $snd) { $snd = [pscustomobject]@{ P = $null; Started = $null; Fails = 0; RetryAt = $null; Gpu = $false; Name = '' }; $script:senders[$sc.N] = $snd }
        if ($snd.P -and -not $snd.P.HasExited) { continue }
        if ($snd.P -and $snd.Started -and ((Get-Date) - $snd.Started).TotalSeconds -lt 3) { $snd.Fails++ } elseif ($snd.P) { $snd.Fails = 0 }
        if ($snd.Fails -ge 2 -and $snd.Gpu) { $script:senderCpuPath = $true; $snd.Fails = 0 }   # GPU path unsupported here
        $snd.P = $null
        if (-not $snd.RetryAt) { $snd.RetryAt = (Get-Date).AddSeconds($(if ($snd.Fails) { [math]::Min(30, 0.5 * [math]::Pow(2, $snd.Fails)) } else { 0 })) }
        if ((Get-Date) -ge $snd.RetryAt) { $snd.RetryAt = $null; Start-SenderFor $sc $snd }
    }
}

$agent = New-Object DeskViewAgent
$agent.Port = $S.ControlPort
$agent.Code = $S.PairCode
$all = [System.Windows.Forms.Screen]::AllScreens
$agent.VL = ($all | % { $_.Bounds.Left } | Measure -Minimum).Minimum
$agent.VR = ($all | % { $_.Bounds.Right } | Measure -Maximum).Maximum
# On the server, the engine links outer edges to the client: control from the client must not trip them.
$agent.AvoidLeftEdge = ($role -eq 'Server'); $agent.AvoidRightEdge = ($role -eq 'Server')
# Which local monitor the viewer's coordinates refer to (the screen it is watching).
function Set-AgentScreen([string]$want) {
    $name = Resolve-Monitor $want
    $m = if ($name -and $name -ne 'Off') { Get-Monitor $name } else { [System.Windows.Forms.Screen]::PrimaryScreen }
    $agent.TL = $m.Bounds.Left; $agent.TT = $m.Bounds.Top; $agent.TW = $m.Bounds.Width; $agent.TH = $m.Bounds.Height
}
Set-AgentScreen '1'
try { $agent.Start() } catch { Notify "Control port $($S.ControlPort) is in use - remote control from the other machine is off." 'Warning' 4000 }

# ============================================================================================================
# VIEWER - players (server: one per monitor showing a client screen; client: one full-screen view)
# ============================================================================================================
$script:players = @{}       # key (local monitor name, or 'view' on the client) -> player state

function New-Player([string]$key, $screen, [int]$remoteN) {
    [pscustomobject]@{
        Key = $key; Screen = $screen; RemoteN = $remoteN; P = $null
        Report = Join-Path $env:TEMP ("deskview-ffplay-$($key -replace '[^\w]', '').log")
        RemoteRes = $null; RemoteRect = $null; Passive = $false; Fails = 0; Legacy = $false; Announced = $false; WarnedDown = $false
        Started = $null; LastStart = (Get-Date '2000-01-01'); ReportLen = -1; ReportGrew = (Get-Date)
    }
}
function Stop-Player($pl) { if ($pl.P -and -not $pl.P.HasExited) { try { $pl.P.Kill() } catch {} }; $pl.P = $null }
function Stop-Players { foreach ($pl in @($script:players.Values)) { Stop-Player $pl }; $script:players = @{} }
function Start-Player($pl) {
    Stop-Player $pl
    if (-not $ffplay) { Notify 'ffplay not found - run DeskView-Setup.ps1.' 'Error' 4000; return }
    $addr = Get-Peer
    if (-not $addr) { return }
    $prof = Get-Profile
    $r = $pl.Screen.Bounds
    $port = $S.VideoPort + $pl.RemoteN - 1
    # A machine still on an old DeskView streams one screen without encryption: after two failed encrypted
    # attempts, try the old way every other time (this only affects what we receive).
    $pl.Legacy = $pl.Fails -ge 2 -and ($pl.Fails % 2) -eq 1
    $enc = if ($pl.Legacy) { '' } else { "&passphrase=$(Get-VideoKey)&pbkeylen=32" }
    $url = "srt://$(Format-Host $addr):${port}?mode=caller&latency=$($latencyMs[$prof] * 1000)&transtype=live&connect_timeout=3000$enc"
    # Fit keeps the remote shape (bars if it differs from the monitor); Stretch fills the monitor.
    $vf = if ($S.Picture -eq 'Stretch') { "-vf scale=$($r.Width):$($r.Height) " } else { '' }
    $hw = if ($pl.Fails -lt 4) { '-hwaccel d3d11va ' } else { '' }   # GPU decode: ~3.5x less CPU
    # An old sender starts slowly (rare key frames): give it time to show its picture size, or nothing appears.
    # A sender that already failed once to show up quickly gets the same patience.
    $probe = if ($pl.Legacy -or $pl.Fails -ge 2) { '-probesize 2000000 -analyzeduration 3000000' } else { '-probesize 32768 -analyzeduration 0' }
    $a = "-hide_banner -loglevel error $hw-fflags nobuffer+discardcorrupt -flags low_delay -framedrop -sync ext " +
         "$probe -an -noborder -alwaysontop $vf" +
         "-left $($r.X) -top $($r.Y) -x $($r.Width) -y $($r.Height) -window_title DeskView `"$url`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo $ffplay, $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['SDL_WINDOWS_DPI_AWARENESS'] = 'permonitorv2'   # 1:1 pixels on scaled monitors
    try { [IO.File]::Delete($pl.Report) } catch {}
    # ffplay's report tells us the remote resolution and which screen it is as soon as the stream opens.
    $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (($pl.Report -replace '\\', '/') -replace ':', '\:') + ':level=32'
    $pl.P = [System.Diagnostics.Process]::Start($psi)
    [DeskViewPortal]::KillWithMe($pl.P)
    $pl.Started = Get-Date; $pl.LastStart = Get-Date
    $pl.ReportLen = -1; $pl.ReportGrew = Get-Date
    $pl.Passive = $false; $pl.RemoteRes = $null
}

# Resolution and (newer senders) which screen it is + where it sits on the remote desktop.
function Read-StreamInfo($pl) {
    if (-not [IO.File]::Exists($pl.Report)) { return $null }
    try { $fs = New-Object IO.FileStream($pl.Report, 'Open', 'Read', 'ReadWrite'); $text = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close() } catch { return $null }
    $m = [regex]::Match($text, 'Video: [^\r\n]*?, (\d{2,5})x(\d{2,5})[ ,\[]')
    if (-not $m.Success) { return $null }
    $info = [pscustomobject]@{ W = [int]$m.Groups[1].Value; H = [int]$m.Groups[2].Value; Rect = $null }
    $r = [regex]::Match($text, 'DeskView\|\d+\|(-?\d+),(-?\d+),(\d+),(\d+)')
    if ($r.Success) { $info.Rect = "$($r.Groups[1].Value),$($r.Groups[2].Value),$($r.Groups[3].Value),$($r.Groups[4].Value)" }
    $info
}

# Where the picture sits on its monitor (Fit adds bars when shapes differ).
function Get-PictureRect($pl) {
    $b = $pl.Screen.Bounds
    if (-not $pl.RemoteRes -or $S.Picture -eq 'Stretch') { return [pscustomobject]@{ L = $b.Left; T = $b.Top; W = $b.Width; H = $b.Height } }
    # [double]: 1920/1920 is an int and would make [math]::Min pick its int overload (0.9 -> 1).
    $scale = [math]::Min([double]$b.Width / $pl.RemoteRes.W, [double]$b.Height / $pl.RemoteRes.H)
    $w = [int][math]::Round($pl.RemoteRes.W * $scale); $h = [int][math]::Round($pl.RemoteRes.H * $scale)
    [pscustomobject]@{ L = $b.Left + [int](($b.Width - $w) / 2); T = $b.Top + [int](($b.Height - $h) / 2); W = $w; H = $h }
}

# ============================================================================================================
# FILES - drag files onto the other computer's picture to send them there (encrypted, paired)
# ============================================================================================================
$script:dropZones = @{}; $script:transfers = @(); $script:lastReceivedNotice = Get-Date '2000-01-01'
function Update-DropZones {
    foreach ($k in @($script:dropZones.Keys)) {
        if (-not $script:players[$k] -or -not $script:players[$k].RemoteRes) { $script:dropZones[$k].Close(); $script:dropZones.Remove($k) }
    }
    foreach ($pl in @($script:players.Values)) {
        if (-not $pl.RemoteRes) { continue }
        $zone = $script:dropZones[$pl.Key]
        if (-not $zone) {
            $zone = New-Object DeskViewDropZone
            $zone.Target = if ($role -eq 'Server') { $remoteName } else { 'the server' }
            $zone.add_Dropped([Action[string[]]]{ param($files) Send-Files $files })
            $script:dropZones[$pl.Key] = $zone
        }
        $pr = Get-PictureRect $pl
        $zone.Place((New-Object System.Drawing.Rectangle $pr.L, $pr.T, $pr.W, $pr.H))
        # the video window puts itself on top; stay above it so drops land here
        $zone.TopMost = $false; $zone.TopMost = $true
    }
}
function Send-Files([string[]]$files) {
    $peer = Get-Peer
    if (-not $peer) { Notify 'The other computer is not connected.' 'Warning'; return }
    $script:transfers += [DeskViewTransfer]::Start((Format-Host $peer).Trim('[', ']'), $S.ControlPort, $S.PairCode, $files)
    Notify "Sending $($files.Count) item(s) to $(if ($role -eq 'Server') { $remoteName } else { 'the server' })..."
}
function Service-Files {
    foreach ($tr in @($script:transfers | ? { $_.Done })) {
        if ($tr.Error) { Notify "Sending failed: $($tr.Error)" 'Warning' 5000 } else { Notify "Sent: $(($tr.Paths | % { Split-Path $_ -Leaf }) -join ', ')" }
    }
    $script:transfers = @($script:transfers | ? { -not $_.Done })
    $got = @(); $p = $null
    while ($agent.Received.TryDequeue([ref]$p)) { $got += $p }
    if ($got.Count) {
        Notify "Received $($got.Count) file(s) in Downloads\DeskView: $(($got | % { Split-Path $_ -Leaf } | Select -First 3) -join ', ')"
        if (((Get-Date) - $script:lastReceivedNotice).TotalSeconds -gt 5) { Start-Process explorer.exe "/select,`"$($got[-1])`"" }
        $script:lastReceivedNotice = Get-Date
    }
}

# ============================================================================================================
# SERVER - portals
# ============================================================================================================
$portal = New-Object DeskViewPortal          # fallback (hook) portal for an engine without portals: one monitor only
$portal.LocalName = $localName
$portal.RemoteName = $remoteName
if ($S.Debug) { $portal.DebugLog = Join-Path $env:TEMP 'deskview-portal.log' }

function Get-EngineLayoutFile {
    $p = Get-IniValue 'externalConfigFile'
    if ($p) { $p -replace '/', '\' } else { $engineLayoutDefault }
}
# The user's own engine screen layout, saved before DeskView changes it the first time.
$layoutBackup = Join-Path $settingsDir 'engine-layout-backup.json'
function Backup-EngineLayout {
    if (Test-Path $layoutBackup) { return }
    $path = Get-EngineLayoutFile
    $ini = Read-EngineIni
    [pscustomobject]@{
        ServerConf     = $path
        Content        = $(if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { $null })
        ExternalConfig = [bool]($ini -match '(?m)^externalConfig=true')
    } | ConvertTo-Json | Set-Content $layoutBackup -Encoding UTF8
}
function Restore-EngineLayout {
    if (-not (Test-Path $layoutBackup)) { return }
    $b = Get-Content $layoutBackup -Raw | ConvertFrom-Json
    if ($null -ne $b.Content) { Write-FileAtomic $b.ServerConf $b.Content }
    if (-not $b.ExternalConfig) {
        $ini = Read-EngineIni
        if ($ini) { Write-FileAtomic $engineIni ($ini -replace '(?m)^externalConfig=true', 'externalConfig=false') }
    }
    [IO.File]::Delete($layoutBackup)
}
function Set-EngineLinks([bool]$leftToRemote, [bool]$rightToRemote) {
    if ($remoteName -eq 'remote') { return }             # partner not known to the engine yet: writing links would break its config
    $L = $localName; $R = $remoteName
    $lines = @('section: links', "`t${L}:")
    if ($rightToRemote) { $lines += "`t`tright = $R" }
    if ($leftToRemote)  { $lines += "`t`tleft = $R" }
    $lines += "`t${R}:"
    if ($rightToRemote) { $lines += "`t`tleft = $L" }
    if ($leftToRemote)  { $lines += "`t`tright = $L" }
    $lines += @('end', '', 'section: options', 'end', '')
    $conf = $lines -join "`r`n"
    $path = Get-EngineLayoutFile
    $old = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($old -eq $conf) { return }
    Backup-EngineLayout
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Write-FileAtomic $path $conf
    # Make sure the engine uses this file, then restart its app so the server loads the new links.
    $ini = Read-EngineIni
    if ($ini -match '(?m)^externalConfig=false') { $ini = $ini -replace '(?m)^externalConfig=false', 'externalConfig=true' }
    elseif ($ini -notmatch '(?m)^externalConfig=') {
        # A fresh engine install has no such keys: add them under [server] so it reads our layout file.
        $keys = "externalConfig=true`r`nexternalConfigFile=$($path -replace '\\', '/')"
        if ($ini -match '(?m)^\[server\]\s*$') { $ini = [regex]::Replace($ini, '(?m)^\[server\]\s*$', "[server]`r`n$keys", 1) } else { $ini = $ini.TrimEnd() + "`r`n`r`n[server]`r`n$keys`r`n" }
    }
    Write-FileAtomic $engineIni $ini
    Get-Process $engineGui -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Start-Process (Join-Path $engineDir "$engineGui.exe") -WindowStyle Minimized
    $script:reinstallAt = (Get-Date).AddSeconds(4)
}
# The DeskView build of the engine handles portals itself (see THIRD_PARTY_NOTICES.md): we only
# tell it where each picture is and which client screen it shows (computer_<name>/portal in its settings).
$nativePortal = Test-Path (Join-Path $engineDir 'deskview.txt')
function Set-NativePortal([string]$value) {
    $ini = Read-EngineIni
    if (-not $ini) { return }
    $section = "[computer_$remoteName]"
    # portalPid lets the engine ignore portals left behind if DeskView dies without cleaning up.
    $line = if ($value) { "portal=`"$value`"`r`nportalPid=$PID" } else { '' }
    $i = $ini.IndexOf($section, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { if (-not $value) { return }; $ini = $ini.TrimEnd() + "`r`n`r`n$section`r`nname=$remoteName`r`n$line`r`n" }
    else {
        $start = $i + $section.Length
        $next = $ini.IndexOf("`n[", $start); if ($next -lt 0) { $next = $ini.Length }
        $body = $ini.Substring($start, $next - $start)
        $old = [regex]::Match($body, '(?m)^portal="?([^"\r\n]*)"?').Groups[1].Value
        if ($old -eq $value -and ($value -eq '' -or $body -match "(?m)^portalPid=$PID\b")) { return }   # unchanged
        $body = [regex]::Replace($body, '(?m)^portal(Pid)?=.*\r?\n?', '')
        if ($line) { $body = $body.TrimEnd("`r", "`n") + "`r`n$line`r`n" }
        $ini = $ini.Substring(0, $start) + $body + $ini.Substring($next)
    }
    Write-FileAtomic $engineIni $ini
}
# Sides of a picture the cursor may leave by: only where everything just outside that side is on a monitor
# and not inside another picture (otherwise leaving would land in a gap, or straight back in the client).
function Get-ExitSides($pr, $others) {
    $mons = @([System.Windows.Forms.Screen]::AllScreens | % { $_.Bounds })
    function OnMonitor($x, $y) {
        foreach ($o in $others) { if ($x -ge $o.L -and $x -lt $o.L + $o.W -and $y -ge $o.T -and $y -lt $o.T + $o.H) { return $false } }
        foreach ($m in $mons) { if ($x -ge $m.Left -and $x -lt $m.Right -and $y -ge $m.Top -and $y -lt $m.Bottom) { return $true } }
        $false
    }
    function Covered($points) { foreach ($p in $points) { if (-not (OnMonitor $p[0] $p[1])) { return $false } }; $true }
    $ys = @(0..20 | % { $pr.T + [int](($pr.H - 1) * $_ / 20) }); $xs = @(0..20 | % { $pr.L + [int](($pr.W - 1) * $_ / 20) })
    $sides = ''
    if (Covered ($ys | % { , @(($pr.L - 1), $_) })) { $sides += 'L' }
    if (Covered ($ys | % { , @(($pr.L + $pr.W), $_) })) { $sides += 'R' }
    if (Covered ($xs | % { , @($_, ($pr.T - 1)) })) { $sides += 'T' }
    if (Covered ($xs | % { , @($_, ($pr.T + $pr.H)) })) { $sides += 'B' }
    if (-not $sides) { 'LRTB' } else { $sides }          # nothing outside fits: let the engine's own bounds decide
}
# Tell the engine about every picture: "x,y,w,h,SIDES[@client screen rect]" separated by ';'.
function Update-Portals {
    $pls = @($script:players.Values | Sort-Object { $_.Screen.Bounds.X })
    if ($S.InputEngine -eq 'DeskView') {
        # DeskView's own engine: work directly on the first live picture through the control link.
        $pl = $pls | ? { $_.RemoteRes } | Select -First 1
        if (-not $S.Interactive -or -not $pl) { $forwarder.Active = $false; return }
        $pr = Get-PictureRect $pl
        $forwarder.VidL = $pr.L; $forwarder.VidT = $pr.T; $forwarder.VidW = $pr.W; $forwarder.VidH = $pr.H
        if ($forwarder.Monitor -ne [string]$pl.RemoteN) { $forwarder.SelectMonitor([string]$pl.RemoteN) }
        $forwarder.Active = $true
        return
    }
    if (-not $S.Interactive -or $pls.Count -eq 0) {
        if ($nativePortal) { Set-NativePortal '' } else { $portal.Enabled = $false; Set-EngineLinks $false $true }
        return
    }
    if ($nativePortal) {
        $portal.Enabled = $false
        $rects = @($pls | % { Get-PictureRect $_ })
        $entries = for ($i = 0; $i -lt $pls.Count; $i++) {
            $pr = $rects[$i]; $others = @($rects | ? { $_ -ne $pr })
            $e = "$($pr.L),$($pr.T),$($pr.W),$($pr.H),$(Get-ExitSides $pr $others)"
            if ($pls[$i].RemoteRect) { $e += "@$($pls[$i].RemoteRect)" }
            # An older sender doesn't say where its screen is: its screen 1 is the main screen, which Windows puts
            # at 0,0. Without this the whole remote desktop is mapped onto the picture (wrong when it has 2+ screens).
            elseif ($pls[$i].RemoteRes -and $pls[$i].RemoteN -eq 1) { $e += "@0,0,$($pls[$i].RemoteRes.W),$($pls[$i].RemoteRes.H)" }
            $e
        }
        # The user's engine layout (edge links) is left exactly as it is: portals work on top of it.
        Set-NativePortal ($entries -join ';')
        return
    }
    # Engine without portals: the hook portal handles the first picture only (the others are view-only).
    $pl = $pls[0]
    $all = [System.Windows.Forms.Screen]::AllScreens
    $b = $pl.Screen.Bounds
    $portal.PL = $b.Left; $portal.PT = $b.Top; $portal.PR = $b.Right; $portal.PB = $b.Bottom
    $portal.VL = ($all | % { $_.Bounds.Left }   | Measure -Minimum).Minimum
    $portal.VR = ($all | % { $_.Bounds.Right }  | Measure -Maximum).Maximum
    $portal.VT = ($all | % { $_.Bounds.Top }    | Measure -Minimum).Minimum
    $portal.VB = ($all | % { $_.Bounds.Bottom } | Measure -Maximum).Maximum
    # Entering from the left uses the engine's right-edge link, entering from the right its left-edge link.
    Set-EngineLinks ($portal.PR -lt $portal.VR) ($portal.PL -gt $portal.VL)
    $pr = Get-PictureRect $pl
    $portal.VidT = $pr.T; $portal.VidH = $pr.H
    $portal.RemoteH = if ($pl.RemoteRes) { $pl.RemoteRes.H } else { 0 }
    $portal.Enabled = $true
    $portal.Reinstall()
}

# ============================================================================================================
# CLIENT - full screen view + control of the server's monitors
# ============================================================================================================
$forwarder = New-Object DeskViewForwarder
$forwarder.Port = $S.ControlPort
$forwarder.Code = $S.PairCode

function Update-ForwarderPicture {
    $pl = $script:players['view']
    if (-not $pl) { return }
    $pr = Get-PictureRect $pl
    $forwarder.VidL = $pr.L; $forwarder.VidT = $pr.T; $forwarder.VidW = $pr.W; $forwarder.VidH = $pr.H
}

# ============================================================================================================
# ACTIONS
# ============================================================================================================
# Which players should exist right now.
function Get-WantedPlayers {
    if ($role -eq 'Server') {
        foreach ($k in @($S.Screens.Keys)) { $m = Get-Monitor $k; if ($m) { [pscustomobject]@{ Key = $k; Screen = $m; N = [int]$S.Screens[$k] } } }
    } elseif ($S.Monitor -ne 'Off') {
        [pscustomobject]@{ Key = 'view'; Screen = [System.Windows.Forms.Screen]::PrimaryScreen; N = [int]$S.Monitor }
    }
}
# Bring the players in line with the settings (start new ones, stop removed or changed ones).
function Sync-Players {
    $wanted = @(Get-WantedPlayers)
    foreach ($k in @($script:players.Keys)) {
        $w = $wanted | ? { $_.Key -eq $k }
        if (-not $w -or $w.N -ne $script:players[$k].RemoteN -or $w.Screen.Bounds -ne $script:players[$k].Screen.Bounds) { Stop-Player $script:players[$k]; $script:players.Remove($k) }
    }
    foreach ($w in $wanted) { if (-not $script:players[$w.Key]) { $pl = New-Player $w.Key $w.Screen $w.N; $script:players[$w.Key] = $pl; Start-Player $pl } }
    Update-DropZones
    if ($role -eq 'Server') { Update-Portals }
    else {
        if ($S.Monitor -eq 'Off') { $forwarder.Active = $false; return }
        $forwarder.Peer = Get-Peer
        $forwarder.SelectMonitor([string]$S.Monitor)   # the server maps our coordinates onto its monitor N
        Update-ForwarderPicture
        $forwarder.Active = $true
    }
}

# Server: show the client's screen $n on local monitor $want (0 = nothing there).
function Set-ScreenOn([string]$want, [int]$n) {
    $name = Resolve-Monitor $want
    if (-not $name -or $name -eq 'Off') { Notify "There is no monitor $want." 'Warning'; return }
    # A stream serves one viewer, so a screen is shown on one monitor at a time: showing it here moves it.
    if ($n -gt 0) { foreach ($k in @($S.Screens.Keys)) { if ($S.Screens[$k] -eq $n) { $S.Screens.Remove($k) } } }
    if ($n -le 0) { $S.Screens.Remove($name) } else { $S.Screens[$name] = $n }
    Save-Settings; Sync-Players; Build-Menu
}

function Show-On([string]$want) {
    # "2=1" / "DISPLAY2=1": local monitor 2 shows the client's screen 1 ("2=0": its own desktop again).
    if ($role -eq 'Server' -and $want -match '^(\w+)=(\d)$') { Set-ScreenOn $Matches[1] ([int]$Matches[2]); return }
    if ($role -eq 'Server') {
        if (-not $want -or $want -eq 'Off') { $S.Screens = @{}; Save-Settings; Sync-Players; Build-Menu; Notify "$remoteName screens off"; return }
        $name = Resolve-Monitor $want
        if (-not $name) { Notify "There is no monitor $want." 'Warning'; return }
        # Hotkeys / -Show move the client's screen 1; screens placed from the menu stay where they are.
        foreach ($k in @($S.Screens.Keys)) { if ($S.Screens[$k] -eq 1) { $S.Screens.Remove($k) } }
        $S.Screens[$name] = 1; $script:lastOn = $name
        Save-Settings; Sync-Players; Build-Menu
        Notify "Connecting to $remoteName's screen for $name..."
    } else {
        $name = if (-not $want -or $want -eq 'Off') { 'Off' } elseif ($want -match '^\d$') { $want } else { Notify "Use a monitor number (1-9) or Off." 'Warning'; return }
        if ($name -ne $S.Monitor) { $S.Monitor = $name; Save-Settings; Sync-Players; Build-Menu }
        if ($name -ne 'Off') { $script:lastOn = $name }
        Notify $(if ($name -eq 'Off') { 'Back to this machine' } else { "Viewing the other machine's monitor $name - Ctrl+Alt+0 to return" })
    }
}

function On-Hotkey($vk) {
    if ($vk -eq 0x30) { Show-On 'Off'; return }
    if ($vk -eq 0x44) {
        if ($role -eq 'Server') {
            $names = @(Get-OrderedMonitors | % { Short $_.DeviceName }) + 'Off'
            $cur = @($S.Screens.Keys | ? { $S.Screens[$_] -eq 1 }) | Select -First 1
            $i = if ($cur) { [array]::IndexOf($names, $cur) } else { $names.Count - 1 }
        } else {
            $names = @('1', '2', '3', 'Off'); $i = [array]::IndexOf($names, [string]$S.Monitor)
        }
        Show-On $names[($i + 1) % $names.Count]; return
    }
    Show-On ([string]($vk - 0x30))
}

# ============================================================================================================
# KEYBOARD & MOUSE ENGINE - the classic separate engine, or DeskView's own switching and clipboard
# ============================================================================================================
function Send-EngineDaemon([string[]]$lines) {
    try {
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "$engineGui-daemon", [IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $w = New-Object IO.StreamWriter($pipe); $w.NewLine = "`n"; $w.AutoFlush = $true
        $ver = (Get-Item (Join-Path $engineDir "$engineGui-daemon.exe")).VersionInfo.ProductVersion
        $w.WriteLine("hello=$ver"); Start-Sleep -Milliseconds 200
        foreach ($l in $lines) { $w.WriteLine($l); Start-Sleep -Milliseconds 300 }
        $pipe.Dispose(); $true
    } catch { $false }
}
function Apply-Builtin {
    $on = $S.InputEngine -eq 'DeskView'
    $side = ([string]$S.Side).ToLowerInvariant()
    $forwarder.Edge = if (-not $on) { '' } elseif ($role -eq 'Server') { $side } else { [DvEdge]::Opposite($side) }
    if (-not $on) { $forwarder.TakeBack() }
    $forwarder.ShareClipboard = $on; $agent.ShareClipboard = $on
    $agent.AvoidLeftEdge = $agent.AvoidRightEdge = ($role -eq 'Server' -and -not $on)
    if ($on -and $S.Peer) { $forwarder.Peer = $S.Peer }
}
function Set-InputEngine([string]$which) {
    $S.InputEngine = $which; Save-Settings
    $cfg = "configFile=$($engineIni -replace '\\', '/')"
    if ($which -eq 'DeskView') {
        if ($role -eq 'Server' -and $nativePortal) { Set-NativePortal '' }
        [void](Send-EngineDaemon @($cfg, 'stop'))
        Notify "DeskView's own keyboard/mouse switching is on (encrypted). Choose the same on $remoteName." 'Info' 5000
    } else {
        $forwarder.Active = $false
        [void](Send-EngineDaemon @($cfg, 'start'))
        Notify 'Classic keyboard/mouse engine is back on.'
    }
    Apply-Builtin; Update-Portals; Build-Menu
}

function Exit-DeskView {
    try { if ($role -eq 'Server') { if ($nativePortal) { Set-NativePortal '' } else { Restore-EngineLayout } } } catch {}
    foreach ($z in @($script:dropZones.Values)) { $z.Close() }
    $forwarder.TakeBack()
    $portal.Stop(); $forwarder.Stop(); $agent.Stop(); Stop-Players; Stop-Senders
    # Leaving with DeskView's own engine on: hand switching back to the classic engine, so the mouse keeps working.
    if ($S.InputEngine -eq 'DeskView') { [void](Send-EngineDaemon @("configFile=$($engineIni -replace '\\', '/')", 'start')) }
    $tray.Visible = $false; [System.Windows.Forms.Application]::Exit()
}

# ============================================================================================================
# MENU
# ============================================================================================================
function Build-Menu {
    $menu.Items.Clear()
    $peer = if ($S.Peer) { $S.Peer } else { 'not connected' }
    $hdr = $menu.Items.Add("$localName ($role)  <->  $remoteName $peer"); $hdr.Enabled = $false
    if ($role -eq 'Server') { $pc = $menu.Items.Add("Pairing code: $($S.PairCode)"); $pc.Enabled = $false }
    $menu.Items.Add('-') | Out-Null

    if ($role -eq 'Server') {
        # One entry per local monitor: which of the client's screens it shows.
        $mons = New-Object System.Windows.Forms.ToolStripMenuItem 'Monitors'
        $num = 0
        foreach ($scr in Get-OrderedMonitors) {
            $num++; $n = Short $scr.DeviceName
            $cur = if ($S.Screens.ContainsKey($n)) { [int]$S.Screens[$n] } else { 0 }
            $pl = $script:players[$n]
            $state = if ($cur) { "$remoteName screen $cur$(if ($pl -and $pl.RemoteRes) { " ($($pl.RemoteRes.W)x$($pl.RemoteRes.H))" })" } else { 'its own desktop' }
            $it = New-Object System.Windows.Forms.ToolStripMenuItem "$num. $n$(if ($scr.Primary) { ' (main)' }) - $state"
            foreach ($k in 0..4) {
                $sub = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($k -eq 0) { 'Its own desktop' } else { "$remoteName screen $k" })
                $sub.Checked = ($cur -eq $k); $sub.Tag = "$n|$k"
                $sub.add_Click({ param($src, $evt) $p = $src.Tag.Split('|'); Set-ScreenOn $p[0] ([int]$p[1]) })
                $it.DropDownItems.Add($sub) | Out-Null
            }
            $mons.DropDownItems.Add($it) | Out-Null
        }
        $mons.DropDownItems.Add('-') | Out-Null
        $allOff = New-Object System.Windows.Forms.ToolStripMenuItem 'All off   Ctrl+Alt+0'
        $allOff.add_Click({ Show-On 'Off' })
        $mons.DropDownItems.Add($allOff) | Out-Null
        $menu.Items.Add($mons) | Out-Null
        $ia = New-Object System.Windows.Forms.ToolStripMenuItem 'Interactive (mouse goes into it)'
        $ia.Checked = [bool]$S.Interactive
        $ia.add_Click({ $S.Interactive = -not $S.Interactive; Save-Settings; Update-Portals; Build-Menu })
        $menu.Items.Add($ia) | Out-Null
    } else {
        $show = New-Object System.Windows.Forms.ToolStripMenuItem 'View + control the other machine'
        foreach ($n in 1..3) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem "Its monitor $n   Ctrl+Alt+$n"
            $it.Checked = ([string]$S.Monitor -eq [string]$n); $it.Tag = [string]$n
            $it.add_Click({ param($src, $evt) Show-On $src.Tag })
            $show.DropDownItems.Add($it) | Out-Null
        }
        $show.DropDownItems.Add('-') | Out-Null
        $off = New-Object System.Windows.Forms.ToolStripMenuItem 'Off   Ctrl+Alt+0'
        $off.Checked = ($S.Monitor -eq 'Off'); $off.add_Click({ Show-On 'Off' })
        $show.DropDownItems.Add($off) | Out-Null
        $menu.Items.Add($show) | Out-Null
    }

    $pic = New-Object System.Windows.Forms.ToolStripMenuItem 'Picture'
    foreach ($p in @(@('Fit', 'Fit - keep shape'), @('Stretch', 'Stretch - fill the monitor'))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p[1]
        $it.Checked = ($S.Picture -eq $p[0]); $it.Tag = $p[0]
        $it.add_Click({ param($src, $evt) $S.Picture = $src.Tag; Save-Settings; Stop-Players; Sync-Players; Build-Menu })
        $pic.DropDownItems.Add($it) | Out-Null
    }
    $menu.Items.Add($pic) | Out-Null

    $q = New-Object System.Windows.Forms.ToolStripMenuItem 'Quality'
    foreach ($p in @(@('Auto', 'Auto (detect)'), @('Wired', 'Wired - 20 Mbps, lowest lag'), @('WiFi', 'Wi-Fi - 10 Mbps, stutter-resistant'))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p[1]
        $it.Checked = ($S.Profile -eq $p[0]); $it.Tag = $p[0]
        $it.add_Click({ param($src, $evt) $S.Profile = $src.Tag; Save-Settings; Stop-Senders; Stop-Players; Sync-Players; Build-Menu })
        $q.DropDownItems.Add($it) | Out-Null
    }
    $menu.Items.Add($q) | Out-Null
    $eng = New-Object System.Windows.Forms.ToolStripMenuItem 'Keyboard && mouse: DeskView built-in (new)'
    $eng.Checked = ($S.InputEngine -eq 'DeskView')
    $eng.add_Click({ Set-InputEngine $(if ($S.InputEngine -eq 'DeskView') { 'Classic' } else { 'DeskView' }) })
    $menu.Items.Add($eng) | Out-Null
    $menu.Items.Add('Reconnect', $null, { Stop-Senders; Stop-Players; Sync-Players }) | Out-Null
    $menu.Items.Add('-') | Out-Null
    $st = $menu.Items.Add("Control channel: $(if ($agent.Client) { 'in use by ' + $agent.Client } elseif ($forwarder.Connected) { 'connected' } else { 'ready' })"); $st.Enabled = $false
    $menu.Items.Add('Exit', $null, { Exit-DeskView }) | Out-Null
}

# ============================================================================================================
# HEARTBEAT (4x a second)
# ============================================================================================================
function Service-Players {
    $changed = $false
    foreach ($pl in @($script:players.Values)) {
        if (-not $pl.P -or $pl.P.HasExited) {
            if ($pl.P -and -not $pl.RemoteRes) {
                $pl.Fails++
                # Say so instead of leaving an empty monitor: the other laptop is not sending this screen.
                if ($pl.Fails -eq 3 -and -not $pl.WarnedDown) {
                    $pl.WarnedDown = $true
                    Notify "No picture from $remoteName screen $($pl.RemoteN) yet. Make sure DeskView is running on $remoteName (same pairing code) and that it is on the network." 'Warning' 8000
                }
            }
            $pl.P = $null
            if (((Get-Date) - $pl.LastStart).TotalSeconds -ge 2) { Start-Player $pl }
            continue
        }
        if (-not $pl.Passive) {
            $pl.P.Refresh()
            # Keep the video window out of Alt+Tab and from taking focus (a stray Esc would close ffplay).
            if ($pl.P.MainWindowHandle -ne [IntPtr]::Zero) { [DeskViewPortal]::MakePassive($pl.P.MainWindowHandle); $pl.Passive = $true; Update-DropZones }
        }
        $len = if ([IO.File]::Exists($pl.Report)) { (New-Object IO.FileInfo $pl.Report).Length } else { 0 }
        if ($len -ne $pl.ReportLen) { $pl.ReportLen = $len; $pl.ReportGrew = Get-Date }
        elseif ($pl.RemoteRes -and ((Get-Date) - $pl.ReportGrew).TotalSeconds -gt 6) {
            # The picture froze (the stream died but ffplay keeps the last frame): reconnect.
            $pl.ReportGrew = Get-Date; Stop-Player $pl; continue
        }
        $info = Read-StreamInfo $pl
        if ($info -and (-not $pl.RemoteRes -or $info.W -ne $pl.RemoteRes.W -or $info.H -ne $pl.RemoteRes.H -or $info.Rect -ne $pl.RemoteRect)) {
            $pl.RemoteRes = [pscustomobject]@{ W = $info.W; H = $info.H }; $pl.RemoteRect = $info.Rect
            $pl.Fails = 0
            if (-not $pl.Announced) { $pl.Announced = $true; $pl.WarnedDown = $false; Notify "$remoteName screen $($pl.RemoteN) is now on $($pl.Key) ($($info.W)x$($info.H))" }
            if ($pl.Legacy -and -not $script:warnedLegacy) {
                $script:warnedLegacy = $true
                Notify "$remoteName runs an old DeskView: its picture is not encrypted. Update it with the install command." 'Warning' 6000
            }
            $changed = $true
        }
    }
    if ($changed) {
        if ($role -eq 'Server') { Update-Portals } else { Update-ForwarderPicture }
        Update-DropZones
        $shown = @($script:players.Values | ? { $_.RemoteRes } | % { "$($_.Key)<-$($_.RemoteN)" }) -join ' '
        Set-TrayText "$remoteName $shown"
        Build-Menu
    }
}

$script:layoutSig = Get-LayoutSignature
$script:lastSlow = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
    try {
        # Hotkeys (physical keyboard only, from the input hook).
        $hk = $forwarder.TakeHotkey()
        if ($hk) { On-Hotkey $hk }

        # Commands from a second copy (DeskView.ps1 -Show ...).
        if ([IO.File]::Exists($commandFile)) {
            $cmd = ([IO.File]::ReadAllText($commandFile)).Trim(); [IO.File]::Delete($commandFile)
            if ($cmd) { Show-On $cmd }
        }

        # Host: the viewer switched to another of our screens (its input now refers to that monitor).
        $req = $agent.TakeRequestedMonitor()
        if ($req) { Set-AgentScreen $req }
        Service-Senders

        if ($script:reinstallAt -and (Get-Date) -ge $script:reinstallAt) { $script:reinstallAt = $null; $portal.Reinstall() }
        Service-Players
        Service-Files

        if (((Get-Date) - $script:lastSlow).TotalSeconds -ge 2) {
            $script:lastSlow = Get-Date
            # Monitors plugged/unplugged or resolution/scaling changed: recompute everything.
            $sig = Get-LayoutSignature
            if ($sig -ne $script:layoutSig) {
                $script:layoutSig = $sig
                $all = [System.Windows.Forms.Screen]::AllScreens
                $agent.VL = ($all | % { $_.Bounds.Left } | Measure -Minimum).Minimum
                $agent.VR = ($all | % { $_.Bounds.Right } | Measure -Maximum).Maximum
                Stop-Senders; Stop-Players; Sync-Players; Build-Menu
                Notify 'Monitor layout changed - adjusted.'
            }
            $before = $S.Peer; [void](Get-Peer); if ($S.Peer -ne $before) { if ($role -eq 'Client' -or $S.InputEngine -eq 'DeskView') { $forwarder.Peer = $S.Peer }; Build-Menu }
        }
    } catch {
        if ($S.Debug) { Add-Content (Join-Path $env:TEMP 'deskview-errors.log') "$(Get-Date -Format s) $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
    }
})

$tray.add_DoubleClick({
    $on = if ($role -eq 'Server') { $S.Screens.Count -gt 0 } else { $S.Monitor -ne 'Off' }
    if ($on) { Show-On 'Off' } else { Show-On $(if ($script:lastOn) { $script:lastOn } else { '1' }) }
})

# --- start ------------------------------------------------------------------------------------------------
[void](Get-Peer)
if ($role -eq 'Client') { $forwarder.Peer = $S.Peer }   # the server only uses the hook for its hotkeys (classic engine)
Apply-Builtin
# Never two engines switching at once: with DeskView's own engine the classic one stays stopped.
if ($S.InputEngine -eq 'DeskView') { [void](Send-EngineDaemon @("configFile=$($engineIni -replace '\\', '/')", 'stop')) }
$forwarder.Start()                       # hotkeys on both roles; input forwarding on the client while viewing
if ($role -eq 'Server' -and -not $nativePortal) { $portal.Start() }
if ($role -eq 'Client' -and $S.Monitor -ne 'Off') { $S.Monitor = 'Off'; Save-Settings }   # start on this machine's own screen
if ($Show) { Show-On $Show }
Service-Senders
Sync-Players
Build-Menu
Set-TrayText "$role - $remoteName $($S.Peer)"
$timer.Start()
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()

<#
  DeskView - see and control the other machine's screens, in both directions, on top of Deskflow.
  The same program runs on both machines; the role comes from Deskflow (server or client).

  On the Deskflow SERVER (the machine with the keyboard/mouse Deskflow shares):
    - Shows the client's screen on any local monitor. Moving the mouse onto that monitor hands keyboard and
      mouse to the client at the same spot (the "portal"); leaving its edge brings you back beside it.
    - Ctrl+Alt+1..9  show the client on local monitor 1..9 (left to right)   Ctrl+Alt+0  off   Ctrl+Alt+D  cycle
  On the Deskflow CLIENT:
    - Ctrl+Alt+1..9  view the server's monitor 1..9 full screen and control it with this machine's own
      keyboard/touchpad (Deskflow can't do this direction).   Ctrl+Alt+0  back to this machine   Ctrl+Alt+D  cycle
  Both machines stream their own screen on request and accept control only from a paired machine
  (pairing code, local network only).

  Run:   powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File DeskView.ps1
  Move:  powershell -ExecutionPolicy Bypass -File DeskView.ps1 -Show 2     (or DISPLAY2, or Off) - tells the running copy
#>
param([string]$Show)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
foreach ($cs in 'DeskView-Portal.cs', 'DeskView-Input.cs', 'DeskView-Dxgi.cs') {
    Add-Type -Path (Join-Path $PSScriptRoot $cs) -ReferencedAssemblies System.Windows.Forms
}
# Work in physical pixels: Deskflow, the hooks and ffplay all do, and scaled monitors otherwise disagree.
[DeskViewPortal]::UsePhysicalPixels()

# --- settings / single instance -------------------------------------------------------------------------
$settingsDir  = Join-Path $env:APPDATA 'DeskView'
$settingsFile = Join-Path $settingsDir 'settings.json'
$commandFile  = Join-Path $settingsDir 'command.txt'
New-Item -ItemType Directory -Force $settingsDir | Out-Null

$mutex = New-Object System.Threading.Mutex($false, 'Local\DeskView')
if (-not $mutex.WaitOne(0)) {
    if ($Show) { Set-Content $commandFile $Show -Encoding ASCII; exit }   # the running copy picks it up
    [System.Windows.Forms.MessageBox]::Show('DeskView is already running (see the tray icon).', 'DeskView') | Out-Null; exit
}

$S = [pscustomobject]@{
    Role = 'Auto'; PairCode = ''; Peer = ''; RemoteName = ''
    Monitor = 'Off'          # server: local monitor showing the client.  client: server monitor being viewed (1..9) or Off
    Profile = 'Auto'; VideoPort = 9000; ControlPort = 9002
    Interactive = $true; Picture = 'Fit'; Encoder = ''; Debug = $false
}
if (Test-Path $settingsFile) {
    try { (Get-Content $settingsFile -Raw | ConvertFrom-Json).psobject.Properties | ? { $S.psobject.Properties[$_.Name] } | % { $S.($_.Name) = $_.Value } } catch {}
}
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

# --- Deskflow: role, peer, names ----------------------------------------------------------------------------
$deskflowIni = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'
# Deskflow's settings file may not exist yet (Deskflow never opened): every read goes through here.
function Read-DeskflowIni { if (Test-Path $deskflowIni) { [IO.File]::ReadAllText($deskflowIni) } else { '' } }
function Get-IniValue([string]$key) { $m = [regex]::Match((Read-DeskflowIni), "(?m)^$([regex]::Escape($key))=(.*)$"); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
function Get-Role {
    if ($S.Role -ne 'Auto') { return $S.Role }
    $mode = Get-IniValue 'coreMode'
    if ($mode -eq '2') { return 'Server' }
    if ($mode -eq '1') { return 'Client' }
    if (Get-NetTCPConnection -LocalPort 24800 -State Listen -ErrorAction SilentlyContinue) { 'Server' } else { 'Client' }
}
function Get-Peer {
    $c = if ($role -eq 'Server') { Get-NetTCPConnection -LocalPort 24800 -State Established -ErrorAction SilentlyContinue }
         else { Get-NetTCPConnection -RemotePort 24800 -State Established -ErrorAction SilentlyContinue }
    $c = $c | Select -First 1
    if ($c -and $S.Peer -ne $c.RemoteAddress) { $S.Peer = $c.RemoteAddress; Save-Settings }
    # Only the Deskflow partner may use the control channel (as itself or IPv4-mapped).
    if ($S.Peer -and $agent) { $agent.AllowedIps = @($S.Peer, "::ffff:$($S.Peer)") }
    $S.Peer
}
# Write via a temp file + replace, so Deskflow never reads a half-written file.
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
        $n = [regex]::Matches((Read-DeskflowIni), '(?m)^\[computer_(.+)\]\s*$') | % { $_.Groups[1].Value } | ? { $_ -ne $localName } | Select -First 1
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
# The video stream is encrypted (SRT AES-256) with a key only the paired machines know.
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
if (-not $S.PairCode) {
    # The server makes the code; the client gets it once during setup (DeskView-Setup.ps1).
    if ($role -eq 'Server') { $S.PairCode = New-PairCode }
    Save-Settings
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
# HOST - stream a local monitor and accept control (both roles)
# ============================================================================================================
$script:sender = $null; $script:senderMonitor = $null; $script:senderFails = 0; $script:senderRetryAt = $null

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

# Which local monitor the host shares: the one the viewer asked for, else the main monitor.
$script:shareMonitor = Short ([System.Windows.Forms.Screen]::PrimaryScreen.DeviceName)

function Stop-Sender { if ($script:sender -and -not $script:sender.HasExited) { try { $script:sender.Kill() } catch {} }; $script:sender = $null }
function Start-Sender {
    Stop-Sender
    if (-not $ffmpeg) { return }
    $outputs = @([DeskViewDxgi]::DdagrabOutputs())
    if ($outputs.Count -eq 0) { return }
    $idx = [array]::IndexOf($outputs, $script:shareMonitor)
    if ($idx -lt 0) { $idx = 0; $script:shareMonitor = $outputs[0] }
    $prof = Get-Profile; $enc = Get-Encoder
    $b = "$($bitrateMbps[$prof])M"; $buf = "$([int]($bitrateMbps[$prof] * 500))k"; $gop = 120
    $encArgs = switch ($enc) {
        'h264_nvenc' { "-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 -rc cbr -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_qsv'   { "-c:v h264_qsv -preset veryfast -look_ahead 0 -async_depth 1 -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_amf'   { "-c:v h264_amf -usage ultralowlatency -quality speed -rc cbr -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
        'h264_mf'    { "-c:v h264_mf -hw_encoding 1 -scenario display_remoting -rate_control cbr -b:v $b -g $gop -bf 0" }
        default      { "-c:v libx264 -preset ultrafast -tune zerolatency -b:v $b -maxrate $b -bufsize $buf -g $gop -bf 0" }
    }
    $url = "srt://0.0.0.0:$($S.VideoPort)?mode=listener&latency=$($latencyMs[$prof] * 1000)&pkt_size=1316&transtype=live&passphrase=$(Get-VideoKey)&pbkeylen=32"
    # Keep captured frames on the GPU when the encoder can take them (about 3x less CPU than copying
    # every frame back for colour conversion); fall back to the CPU path if the GPU path keeps failing.
    $cap = "ddagrab=output_idx=${idx}:framerate=60:draw_mouse=1"
    $gpu = -not $script:senderCpuPath
    $chain = if ($gpu -and $enc -eq 'h264_qsv') { "$cap,hwmap=derive_device=qsv,format=qsv"; $pix = '' }
             elseif ($gpu -and $enc -in 'h264_nvenc', 'h264_amf') { $cap; $pix = '' }
             else { "$cap,hwdownload,format=bgra"; $pix = '-pix_fmt nv12' }
    $script:senderGpu = $chain -notmatch 'hwdownload'
    $a = "-hide_banner -loglevel error -f lavfi -i $chain $pix $encArgs -flush_packets 1 -f mpegts -mpegts_flags resend_headers `"$url`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg, $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $script:sender = [System.Diagnostics.Process]::Start($psi)
    [DeskViewPortal]::KillWithMe($script:sender)
    $script:senderStarted = Get-Date
    $script:senderMonitor = $script:shareMonitor
    # Tell the agent which rectangle the viewer's coordinates refer to.
    $m = Get-Monitor $script:shareMonitor
    if ($m) { $agent.TL = $m.Bounds.Left; $agent.TT = $m.Bounds.Top; $agent.TW = $m.Bounds.Width; $agent.TH = $m.Bounds.Height }
}

$agent = New-Object DeskViewAgent
$agent.Port = $S.ControlPort
$agent.Code = $S.PairCode
$all = [System.Windows.Forms.Screen]::AllScreens
$agent.VL = ($all | % { $_.Bounds.Left } | Measure -Minimum).Minimum
$agent.VR = ($all | % { $_.Bounds.Right } | Measure -Maximum).Maximum
# On the server, Deskflow links outer edges to the client: control from the client must not trip them.
$agent.AvoidLeftEdge = ($role -eq 'Server'); $agent.AvoidRightEdge = ($role -eq 'Server')
try { $agent.Start() } catch { Notify "Control port $($S.ControlPort) is in use - remote control from the other machine is off." 'Warning' 4000 }

# ============================================================================================================
# VIEWER - shared player (portal monitor on the server, full screen on the client)
# ============================================================================================================
$script:player = $null; $script:remoteRes = $null; $script:playerPassive = $false; $script:playerFails = 0; $script:playerLegacy = $false
$reportFile = Join-Path $env:TEMP 'deskview-ffplay.log'

function Stop-Player { if ($script:player -and -not $script:player.HasExited) { try { $script:player.Kill() } catch {} }; $script:player = $null }
function Start-Player($screen) {
    Stop-Player
    if (-not $ffplay) { Notify 'ffplay not found - run DeskView-Setup.ps1.' 'Error' 4000; return }
    $addr = Get-Peer
    if (-not $addr) { Notify 'The other machine is not connected through Deskflow yet.' 'Warning' 3000; return }
    $prof = Get-Profile
    $r = $screen.Bounds
    # A machine still on an old DeskView streams without encryption: after two failed encrypted attempts,
    # try the old way every other time (this only affects what we receive; our own stream stays encrypted).
    $script:playerLegacy = $script:playerFails -ge 2 -and ($script:playerFails % 2) -eq 1
    $enc = if ($script:playerLegacy) { '' } else { "&passphrase=$(Get-VideoKey)&pbkeylen=32" }
    $url = "srt://$(Format-Host $addr):$($S.VideoPort)?mode=caller&latency=$($latencyMs[$prof] * 1000)&transtype=live&connect_timeout=3000$enc"
    # Fit keeps the remote shape (bars if it differs from the monitor); Stretch fills the monitor.
    $vf = if ($S.Picture -eq 'Stretch') { "-vf scale=$($r.Width):$($r.Height) " } else { '' }
    $hw = if ($script:playerFails -lt 4) { '-hwaccel d3d11va ' } else { '' }   # GPU decode: ~3.5x less CPU
    $a = "-hide_banner -loglevel error $hw-fflags nobuffer+discardcorrupt -flags low_delay -framedrop -sync ext " +
         "-probesize 32768 -analyzeduration 0 -an -noborder -alwaysontop $vf" +
         "-left $($r.X) -top $($r.Y) -x $($r.Width) -y $($r.Height) -window_title DeskView `"$url`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo $ffplay, $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['SDL_WINDOWS_DPI_AWARENESS'] = 'permonitorv2'   # 1:1 pixels on scaled monitors
    try { [IO.File]::Delete($reportFile) } catch {}
    # ffplay's report tells us the remote resolution as soon as the stream opens.
    $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (($reportFile -replace '\\', '/') -replace ':', '\:') + ':level=32'
    $script:player = [System.Diagnostics.Process]::Start($psi)
    [DeskViewPortal]::KillWithMe($script:player)
    $script:playerStarted = Get-Date
    $script:reportLen = -1; $script:reportGrew = Get-Date
    $script:playerPassive = $false
    $script:remoteRes = $null
    $script:playerScreen = $screen
}

function Read-RemoteResolution {
    if (-not [IO.File]::Exists($reportFile)) { return $null }
    try { $fs = New-Object IO.FileStream($reportFile, 'Open', 'Read', 'ReadWrite'); $text = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close() } catch { return $null }
    $m = [regex]::Match($text, 'Video: [^\r\n]*?, (\d{2,5})x(\d{2,5})[ ,\[]')
    if ($m.Success) { [pscustomobject]@{ W = [int]$m.Groups[1].Value; H = [int]$m.Groups[2].Value } } else { $null }
}

# Where the picture sits on its monitor (Fit adds bars when shapes differ).
function Get-PictureRect($screen) {
    $b = $screen.Bounds
    if (-not $script:remoteRes -or $S.Picture -eq 'Stretch') { return [pscustomobject]@{ L = $b.Left; T = $b.Top; W = $b.Width; H = $b.Height } }
    # [double]: 1920/1920 is an int and would make [math]::Min pick its int overload (0.9 -> 1).
    $scale = [math]::Min([double]$b.Width / $script:remoteRes.W, [double]$b.Height / $script:remoteRes.H)
    $w = [int][math]::Round($script:remoteRes.W * $scale); $h = [int][math]::Round($script:remoteRes.H * $scale)
    [pscustomobject]@{ L = $b.Left + [int](($b.Width - $w) / 2); T = $b.Top + [int](($b.Height - $h) / 2); W = $w; H = $h }
}

# ============================================================================================================
# SERVER VIEWER - the portal
# ============================================================================================================
$portal = New-Object DeskViewPortal
$portal.LocalName = $localName
$portal.RemoteName = $remoteName
if ($S.Debug) { $portal.DebugLog = Join-Path $env:TEMP 'deskview-portal.log' }

function Get-DeskflowServerConf {
    $p = Get-IniValue 'externalConfigFile'
    if ($p) { $p -replace '/', '\' } else { 'C:\ProgramData\Deskflow\deskflow-server.conf' }
}
# The user's own Deskflow screen layout, saved before DeskView changes it the first time.
$layoutBackup = Join-Path $settingsDir 'deskflow-layout-backup.json'
function Backup-DeskflowLayout {
    if (Test-Path $layoutBackup) { return }
    $path = Get-DeskflowServerConf
    $ini = Read-DeskflowIni
    [pscustomobject]@{
        ServerConf     = $path
        Content        = $(if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { $null })
        ExternalConfig = [bool]($ini -match '(?m)^externalConfig=true')
    } | ConvertTo-Json | Set-Content $layoutBackup -Encoding UTF8
}
function Restore-DeskflowLayout {
    if (-not (Test-Path $layoutBackup)) { return }
    $b = Get-Content $layoutBackup -Raw | ConvertFrom-Json
    if ($null -ne $b.Content) { Write-FileAtomic $b.ServerConf $b.Content }
    if (-not $b.ExternalConfig) {
        $ini = Read-DeskflowIni
        if ($ini) { Write-FileAtomic $deskflowIni ($ini -replace '(?m)^externalConfig=true', 'externalConfig=false') }
    }
    [IO.File]::Delete($layoutBackup)
}
function Set-DeskflowLinks([bool]$leftToRemote, [bool]$rightToRemote) {
    if ($remoteName -eq 'remote') { return }             # partner not known to Deskflow yet: writing links would break its config
    $L = $localName; $R = $remoteName
    $lines = @('section: links', "`t${L}:")
    if ($rightToRemote) { $lines += "`t`tright = $R" }
    if ($leftToRemote)  { $lines += "`t`tleft = $R" }
    $lines += "`t${R}:"
    if ($rightToRemote) { $lines += "`t`tleft = $L" }
    if ($leftToRemote)  { $lines += "`t`tright = $L" }
    $lines += @('end', '', 'section: options', 'end', '')
    $conf = $lines -join "`r`n"
    $path = Get-DeskflowServerConf
    $old = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($old -eq $conf) { return }
    Backup-DeskflowLayout
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Write-FileAtomic $path $conf
    # Make sure Deskflow uses this file, then restart the app so its server core loads the new links.
    $ini = Read-DeskflowIni
    if ($ini -match '(?m)^externalConfig=false') { $ini = $ini -replace '(?m)^externalConfig=false', 'externalConfig=true' }
    elseif ($ini -notmatch '(?m)^externalConfig=') {
        # A fresh Deskflow has no such keys: add them under [server] so it reads our layout file.
        $keys = "externalConfig=true`r`nexternalConfigFile=$($path -replace '\\', '/')"
        if ($ini -match '(?m)^\[server\]\s*$') { $ini = [regex]::Replace($ini, '(?m)^\[server\]\s*$', "[server]`r`n$keys", 1) } else { $ini = $ini.TrimEnd() + "`r`n`r`n[server]`r`n$keys`r`n" }
    }
    Write-FileAtomic $deskflowIni $ini
    Get-Process deskflow -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Start-Process 'C:\Program Files\Deskflow\deskflow.exe' -WindowStyle Minimized
    $script:reinstallAt = (Get-Date).AddSeconds(4)
}
# Deskflow built with DeskView (github.com/xl337x/deskflow, branch deskview) handles the portal itself:
# we only tell it where the picture is (computer_<name>/portal in its settings) - no mouse hook, no edge links.
$nativePortal = Test-Path 'C:\Program Files\Deskflow\deskview.txt'
function Set-NativePortal([string]$value) {
    $ini = Read-DeskflowIni
    if (-not $ini) { return }
    $section = "[computer_$remoteName]"
    # portalPid lets Deskflow ignore a portal left behind if DeskView dies without cleaning up.
    $line = if ($value) { "portal=`"$value`"`r`nportalPid=$PID" } else { '' }
    $i = $ini.IndexOf($section, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { if (-not $value) { return }; $ini = $ini.TrimEnd() + "`r`n`r`n$section`r`nname=$remoteName`r`n$line`r`n" }
    else {
        $start = $i + $section.Length
        $next = $ini.IndexOf("`n[", $start); if ($next -lt 0) { $next = $ini.Length }
        $body = $ini.Substring($start, $next - $start)
        $body = [regex]::Replace($body, '(?m)^portal(Pid)?=.*\r?\n?', '')
        if ($line) { $body = $body.TrimEnd("`r", "`n") + "`r`n$line`r`n" }
        $ini = $ini.Substring(0, $start) + $body + $ini.Substring($next)
    }
    Write-FileAtomic $deskflowIni $ini
}
# Sides of the picture the cursor may leave by: only where everything just outside that side is on a
# monitor (otherwise leaving would land in a gap between monitors and bounce back in).
function Get-ExitSides($pr) {
    $mons = @([System.Windows.Forms.Screen]::AllScreens | % { $_.Bounds })
    function OnMonitor($x, $y) { foreach ($m in $mons) { if ($x -ge $m.Left -and $x -lt $m.Right -and $y -ge $m.Top -and $y -lt $m.Bottom) { return $true } }; $false }
    function Covered($points) { foreach ($p in $points) { if (-not (OnMonitor $p[0] $p[1])) { return $false } }; $true }
    $ys = @(0..20 | % { $pr.T + [int](($pr.H - 1) * $_ / 20) }); $xs = @(0..20 | % { $pr.L + [int](($pr.W - 1) * $_ / 20) })
    $sides = ''
    if (Covered ($ys | % { , @(($pr.L - 1), $_) })) { $sides += 'L' }
    if (Covered ($ys | % { , @(($pr.L + $pr.W), $_) })) { $sides += 'R' }
    if (Covered ($xs | % { , @($_, ($pr.T - 1)) })) { $sides += 'T' }
    if (Covered ($xs | % { , @($_, ($pr.T + $pr.H)) })) { $sides += 'B' }
    if (-not $sides) { 'LRTB' } else { $sides }          # nothing outside fits: let Deskflow's own bounds decide
}
function Update-PortalVideo {
    if (-not $script:playerScreen) { return }
    $pr = Get-PictureRect $script:playerScreen
    if ($nativePortal) { if ($S.Monitor -ne 'Off' -and $S.Interactive) { Set-NativePortal "$($pr.L),$($pr.T),$($pr.W),$($pr.H),$(Get-ExitSides $pr)" }; return }
    $portal.VidT = $pr.T; $portal.VidH = $pr.H
    $portal.RemoteH = if ($script:remoteRes) { $script:remoteRes.H } else { 0 }
}
function Update-Portal {
    $scr = if ($S.Monitor -ne 'Off') { Get-Monitor $S.Monitor }
    if ($nativePortal) {
        $portal.Enabled = $false
        # The user's Deskflow layout (edge links) is left exactly as it is: the portal works on top of it.
        if (-not $scr -or -not $S.Interactive) { Set-NativePortal ''; return }
        $script:playerScreen = $scr
        Update-PortalVideo
        return
    }
    if (-not $scr -or -not $S.Interactive) { $portal.Enabled = $false; Set-DeskflowLinks $false $true; return }
    $all = [System.Windows.Forms.Screen]::AllScreens
    $b = $scr.Bounds
    $portal.PL = $b.Left; $portal.PT = $b.Top; $portal.PR = $b.Right; $portal.PB = $b.Bottom
    $portal.VL = ($all | % { $_.Bounds.Left }   | Measure -Minimum).Minimum
    $portal.VR = ($all | % { $_.Bounds.Right }  | Measure -Maximum).Maximum
    $portal.VT = ($all | % { $_.Bounds.Top }    | Measure -Minimum).Minimum
    $portal.VB = ($all | % { $_.Bounds.Bottom } | Measure -Maximum).Maximum
    # Entering from the left uses Deskflow's right-edge link, entering from the right its left-edge link.
    Set-DeskflowLinks ($portal.PR -lt $portal.VR) ($portal.PL -gt $portal.VL)
    $script:playerScreen = $scr
    Update-PortalVideo
    $portal.Enabled = $true
    $portal.Reinstall()
}

# ============================================================================================================
# CLIENT VIEWER - full screen view + control of the server's monitors
# ============================================================================================================
$forwarder = New-Object DeskViewForwarder
$forwarder.Port = $S.ControlPort
$forwarder.Code = $S.PairCode

function Update-ForwarderPicture {
    if (-not $script:playerScreen) { return }
    $pr = Get-PictureRect $script:playerScreen
    $forwarder.VidL = $pr.L; $forwarder.VidT = $pr.T; $forwarder.VidW = $pr.W; $forwarder.VidH = $pr.H
}

# ============================================================================================================
# ACTIONS
# ============================================================================================================
function Apply-Monitor {
    if ($role -eq 'Server') {
        Update-Portal
        if ($S.Monitor -ne 'Off') { Start-Player (Get-Monitor $S.Monitor) } else { Stop-Player }
    } else {
        if ($S.Monitor -eq 'Off') { $forwarder.Active = $false; Stop-Player; return }
        $forwarder.Peer = Get-Peer
        $forwarder.SelectMonitor($S.Monitor)           # the server streams its monitor N
        Start-Player ([System.Windows.Forms.Screen]::PrimaryScreen)
        Update-ForwarderPicture
        $forwarder.Active = $true
    }
}

function Show-On([string]$want) {
    if ($role -eq 'Server') {
        $name = Resolve-Monitor $want
        if (-not $name) { Notify "There is no monitor $want." 'Warning'; return }
    } else {
        $name = if (-not $want -or $want -eq 'Off') { 'Off' } elseif ($want -match '^\d$') { $want } else { Notify "Use a monitor number (1-9) or Off." 'Warning'; return }
    }
    if ($name -ne $S.Monitor) { $S.Monitor = $name; Save-Settings; Apply-Monitor; Build-Menu }
    if ($role -eq 'Server') { Notify $(if ($name -eq 'Off') { "$remoteName screen off" } else { "$remoteName shown on $name" }) }
    else { Notify $(if ($name -eq 'Off') { 'Back to this machine' } else { "Viewing the other machine's monitor $name - Ctrl+Alt+0 to return" }) }
}

function On-Hotkey($vk) {
    if ($vk -eq 0x30) { Show-On 'Off'; return }
    if ($vk -eq 0x44) {
        $names = if ($role -eq 'Server') { @(Get-OrderedMonitors | % { Short $_.DeviceName }) } else { @('1', '2', '3') }
        $names += 'Off'
        $i = [array]::IndexOf($names, [string]$S.Monitor)
        Show-On $names[($i + 1) % $names.Count]; return
    }
    Show-On ([string]($vk - 0x30))
}

function Exit-DeskView {
    try { if ($role -eq 'Server') { if ($nativePortal) { Set-NativePortal '' } else { Restore-DeskflowLayout } } } catch {}
    $portal.Stop(); $forwarder.Stop(); $agent.Stop(); Stop-Player; Stop-Sender
    $tray.Visible = $false; [System.Windows.Forms.Application]::Exit()
}

# ============================================================================================================
# MENU
# ============================================================================================================
function Build-Menu {
    $menu.Items.Clear()
    $res = if ($script:remoteRes) { "  $($script:remoteRes.W)x$($script:remoteRes.H)" } else { '' }
    $peer = if ($S.Peer) { $S.Peer } else { 'not connected' }
    $hdr = $menu.Items.Add("$localName ($role)  <->  $remoteName $peer$res"); $hdr.Enabled = $false
    if ($role -eq 'Server') { $pc = $menu.Items.Add("Pairing code: $($S.PairCode)"); $pc.Enabled = $false }
    $menu.Items.Add('-') | Out-Null

    if ($role -eq 'Server') {
        $show = New-Object System.Windows.Forms.ToolStripMenuItem "Show $remoteName on"
        $num = 0
        foreach ($scr in Get-OrderedMonitors) {
            $num++; $n = Short $scr.DeviceName
            $it = New-Object System.Windows.Forms.ToolStripMenuItem "$num. $n  ($($scr.Bounds.Width)x$($scr.Bounds.Height)$(if ($scr.Primary) { ', main' }))   Ctrl+Alt+$num"
            $it.Checked = ($S.Monitor -eq $n); $it.Tag = $n
            $it.add_Click({ param($src, $evt) Show-On $src.Tag })
            $show.DropDownItems.Add($it) | Out-Null
        }
        $ia = New-Object System.Windows.Forms.ToolStripMenuItem 'Interactive (mouse goes into it)'
        $ia.Checked = [bool]$S.Interactive
        $ia.add_Click({ $S.Interactive = -not $S.Interactive; Save-Settings; Update-Portal; Build-Menu })
    } else {
        $show = New-Object System.Windows.Forms.ToolStripMenuItem 'View + control the other machine'
        foreach ($n in 1..3) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem "Its monitor $n   Ctrl+Alt+$n"
            $it.Checked = ([string]$S.Monitor -eq [string]$n); $it.Tag = [string]$n
            $it.add_Click({ param($src, $evt) Show-On $src.Tag })
            $show.DropDownItems.Add($it) | Out-Null
        }
        $ia = $null
    }
    $show.DropDownItems.Add('-') | Out-Null
    $off = New-Object System.Windows.Forms.ToolStripMenuItem 'Off   Ctrl+Alt+0'
    $off.Checked = ($S.Monitor -eq 'Off'); $off.add_Click({ Show-On 'Off' })
    $show.DropDownItems.Add($off) | Out-Null
    $menu.Items.Add($show) | Out-Null
    if ($ia) { $menu.Items.Add($ia) | Out-Null }

    $pic = New-Object System.Windows.Forms.ToolStripMenuItem 'Picture'
    foreach ($p in @(@('Fit', 'Fit - keep shape'), @('Stretch', 'Stretch - fill the monitor'))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p[1]
        $it.Checked = ($S.Picture -eq $p[0]); $it.Tag = $p[0]
        $it.add_Click({ param($src, $evt) $S.Picture = $src.Tag; Save-Settings; Apply-Monitor; Build-Menu })
        $pic.DropDownItems.Add($it) | Out-Null
    }
    $menu.Items.Add($pic) | Out-Null

    $q = New-Object System.Windows.Forms.ToolStripMenuItem 'Quality'
    foreach ($p in @(@('Auto', 'Auto (detect)'), @('Wired', 'Wired - 20 Mbps, lowest lag'), @('WiFi', 'Wi-Fi - 10 Mbps, stutter-resistant'))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p[1]
        $it.Checked = ($S.Profile -eq $p[0]); $it.Tag = $p[0]
        $it.add_Click({ param($src, $evt) $S.Profile = $src.Tag; Save-Settings; Start-Sender; Apply-Monitor; Build-Menu })
        $q.DropDownItems.Add($it) | Out-Null
    }
    $menu.Items.Add($q) | Out-Null
    $menu.Items.Add('Reconnect', $null, { Start-Sender; Apply-Monitor }) | Out-Null
    $menu.Items.Add('-') | Out-Null
    $st = $menu.Items.Add("Control channel: $(if ($agent.Client) { 'in use by ' + $agent.Client } elseif ($forwarder.Connected) { 'connected' } else { 'ready' })"); $st.Enabled = $false
    $menu.Items.Add('Exit', $null, {
        Exit-DeskView
    }) | Out-Null
}

# ============================================================================================================
# HEARTBEAT (4x a second)
# ============================================================================================================
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

        # Host: the viewer asked for another monitor, or the stream ended (listener exits after each session).
        $req = $agent.TakeRequestedMonitor()
        if ($req) {
            $name = Resolve-Monitor $req
            if ($name -and $name -ne 'Off' -and $name -ne $script:senderMonitor) { $script:shareMonitor = $name; Start-Sender }
        }
        if (-not $script:sender -or $script:sender.HasExited) {
            # The listener exits after each viewing session (restart at once); if it keeps dying within a few
            # seconds (port taken, locked screen, encoder trouble) wait longer each time, up to 30 s.
            if ($script:sender -and $script:senderStarted -and ((Get-Date) - $script:senderStarted).TotalSeconds -lt 3) { $script:senderFails++ } elseif ($script:sender) { $script:senderFails = 0 }
            if ($script:senderFails -ge 2 -and $script:senderGpu) { $script:senderCpuPath = $true; $script:senderFails = 0 }   # GPU path unsupported here
            $wait = if ($script:senderFails) { [math]::Min(30, 0.5 * [math]::Pow(2, $script:senderFails)) } else { 0 }
            if (-not $script:senderRetryAt) { $script:senderRetryAt = (Get-Date).AddSeconds($wait) }
            if ((Get-Date) -ge $script:senderRetryAt) { $script:senderRetryAt = $null; Start-Sender }
        }

        if ($script:reinstallAt -and (Get-Date) -ge $script:reinstallAt) { $script:reinstallAt = $null; $portal.Reinstall() }

        if ($S.Monitor -ne 'Off') {
            if (-not $script:player -or $script:player.HasExited) {
                if ($script:player -and -not $script:remoteRes) { $script:playerFails++ }
                if (((Get-Date) - $script:lastPlayerStart).TotalSeconds -ge 2) { $script:lastPlayerStart = Get-Date; Apply-Monitor }
            } else {
                if (-not $script:playerPassive) {
                    $script:player.Refresh()
                    # Keep the video window out of Alt+Tab and from taking focus (a stray Esc would close ffplay).
                    if ($script:player.MainWindowHandle -ne [IntPtr]::Zero) { [DeskViewPortal]::MakePassive($script:player.MainWindowHandle); $script:playerPassive = $true }
                }
                $len = if ([IO.File]::Exists($reportFile)) { (New-Object IO.FileInfo $reportFile).Length } else { 0 }
                if ($len -ne $script:reportLen) { $script:reportLen = $len; $script:reportGrew = Get-Date }
                elseif ($script:remoteRes -and ((Get-Date) - $script:reportGrew).TotalSeconds -gt 6) {
                    # The picture froze (the stream died but ffplay keeps the last frame): reconnect.
                    $script:reportGrew = Get-Date; Stop-Player
                }
                $res = Read-RemoteResolution
                if ($res -and (-not $script:remoteRes -or $res.W -ne $script:remoteRes.W -or $res.H -ne $script:remoteRes.H)) {
                    $script:remoteRes = $res
                    $script:playerFails = 0
                    if ($script:playerLegacy -and -not $script:warnedLegacy) {
                        $script:warnedLegacy = $true
                        Notify "$remoteName runs an old DeskView: its picture is not encrypted. Update it with the install command." 'Warning' 6000
                    }
                    if ($role -eq 'Server') { Update-PortalVideo } else { Update-ForwarderPicture }
                    Set-TrayText "$remoteName $($res.W)x$($res.H) on $(if ($role -eq 'Server') { $S.Monitor } else { 'this screen' })"
                    Build-Menu
                }
            }
        }

        if (((Get-Date) - $script:lastSlow).TotalSeconds -ge 2) {
            $script:lastSlow = Get-Date
            # Monitors plugged/unplugged or resolution/scaling changed: recompute everything.
            $sig = Get-LayoutSignature
            if ($sig -ne $script:layoutSig) {
                $script:layoutSig = $sig
                if ($role -eq 'Server' -and $S.Monitor -ne 'Off' -and -not (Get-Monitor $S.Monitor)) { $S.Monitor = 'Off'; Save-Settings }
                $all = [System.Windows.Forms.Screen]::AllScreens
                $agent.VL = ($all | % { $_.Bounds.Left } | Measure -Minimum).Minimum
                $agent.VR = ($all | % { $_.Bounds.Right } | Measure -Maximum).Maximum
                Start-Sender; Apply-Monitor; Build-Menu
                Notify 'Monitor layout changed - adjusted.'
            }
            $before = $S.Peer; [void](Get-Peer); if ($S.Peer -ne $before) { if ($role -eq 'Client') { $forwarder.Peer = $S.Peer }; Build-Menu }
        }
    } catch {
        if ($S.Debug) { Add-Content (Join-Path $env:TEMP 'deskview-errors.log') "$(Get-Date -Format s) $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
    }
})
$script:lastPlayerStart = Get-Date '2000-01-01'

$tray.add_DoubleClick({ if ($S.Monitor -eq 'Off') { Show-On $(if ($script:lastOn) { $script:lastOn } else { '1' }) } else { Show-On 'Off' } })

# --- start ------------------------------------------------------------------------------------------------
if ($Show) { $want = if ($role -eq 'Server') { Resolve-Monitor $Show } else { $Show }; if ($want) { $S.Monitor = $want; Save-Settings } }
[void](Get-Peer)
if ($role -eq 'Client') { $forwarder.Peer = $S.Peer }   # the server only uses the hook for its hotkeys
$forwarder.Start()                       # hotkeys on both roles; input forwarding on the client while viewing
if ($role -eq 'Server' -and -not $nativePortal) { $portal.Start() }
Start-Sender
if ($role -eq 'Client' -and $S.Monitor -ne 'Off') { $S.Monitor = 'Off'; Save-Settings }   # start on this machine's own screen
Apply-Monitor
Build-Menu
Set-TrayText "$role - $remoteName $($S.Peer)"
$timer.Start()
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()

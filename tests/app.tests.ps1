# Tests for the DeskView app's logic: compiles and loads app\**\*.cs exactly like DeskView.ps1 does for users, and checks its building blocks
# without starting the app. Build it first: gui\build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Web.Extensions
& (Join-Path $PSScriptRoot '..\app\DeskView.ps1') -LoadOnly
$asm = [DeskView.Program].Assembly
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }
$T = { param($n) $asm.GetType($n, $true) }
$bf = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'

# ---------------------------------------------------------------------------------------------- pairing codes
$Settings = & $T 'DeskView.AppSettings'
$codes = 1..200 | % { $Settings::NewPairCode() }
Check 'pairing codes: 12 characters from the unambiguous alphabet' (($codes | ? { $_ -notmatch '^[2-9A-HJKMNP-Z]{12}$' }).Count -eq 0)
Check 'pairing codes: all different (200 samples)' (($codes | Select -Unique).Count -eq 200)
Check 'code check accepts 8-12 valid characters, any case' ($Settings::IsValidPairCode('k7mpq3xr') -and $Settings::IsValidPairCode('ABCDEFGH2345'))
Check 'code check rejects ambiguous / short / long codes' (-not $Settings::IsValidPairCode('ABCDEFG') -and -not $Settings::IsValidPairCode('ABCDEFGH0') -and -not $Settings::IsValidPairCode('ABCDEFGHJKMNP'))

# ---------------------------------------------------------------------------------------------- video key = script version
$s = [Activator]::CreateInstance($Settings); $s.PairCode = 'K7MPQ3XR'
$sha = [Security.Cryptography.SHA256]::Create(); $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('DeskView-video-v2:K7MPQ3XR'))
$scriptKey = -join ($h[0..15] | % { $_.ToString('x2') })
Check 'video key identical to the PowerShell DeskView (they interoperate)' ($s.VideoKey() -eq $scriptKey) "app=$($s.VideoKey()) script=$scriptKey"
$s.PairCode = ' k7mpq3xr '
Check 'video key ignores case and spaces in the code' ($s.VideoKey() -eq $scriptKey)

# ---------------------------------------------------------------------------------------------- settings JSON round trip
$s2 = [Activator]::CreateInstance($Settings)
$s2.Role = [Enum]::Parse((& $T 'DeskView.Role'), 'Server'); $s2.RemoteName = 'LAPTOP'; $s2.Screens['DISPLAY1'] = 1; $s2.Screens['DISPLAY2'] = 2
$s2.SwitchDelayEnabled = $true; $s2.SwitchDelayMs = 333; $s2.RemoteSide = [Enum]::Parse((& $T 'DeskView.Side'), 'Bottom')
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$back = $ser.Deserialize($ser.Serialize($s2), $Settings)
Check 'settings survive a save/load round trip' ($back.RemoteName -eq 'LAPTOP' -and $back.Screens['DISPLAY2'] -eq 2 -and $back.SwitchDelayMs -eq 333 -and "$($back.RemoteSide)" -eq 'Bottom' -and "$($back.Role)" -eq 'Server')

# ---------------------------------------------------------------------------------------------- engine choice kept on update
$tmpHome = Join-Path $env:TEMP "dv-app-old-$PID"; New-Item -ItemType Directory -Force $tmpHome | Out-Null
Set-Content (Join-Path $tmpHome 'app.json') '{"Role":1,"PairCode":"K7MPQ3XR","RemoteName":"LAPTOP"}' -Encoding UTF8
[Environment]::SetEnvironmentVariable('DESKVIEW_HOME', $tmpHome)
$loaded = $Settings::Load()
Check 'settings from before the engine choice keep the classic engine (an update never switches it)' ($loaded.InputEngine -eq 'Classic') $loaded.InputEngine
[Environment]::SetEnvironmentVariable('DESKVIEW_HOME', $null); [IO.Directory]::Delete($tmpHome, $true)

# ---------------------------------------------------------------------------------------------- engine settings + layout
$Core = & $T 'DeskView.CoreControl'
$cfgPath = $Core::ConfigPath; $layoutPath = $Core::LayoutPath
$saved = @{}; foreach ($p in $cfgPath, $layoutPath) { if (Test-Path $p) { $saved[$p] = [IO.File]::ReadAllText($p) } }
try {
    foreach ($side in 'Left', 'Right', 'Top', 'Bottom') {
        $s2.RemoteSide = [Enum]::Parse((& $T 'DeskView.Side'), $side); $s2.ComputerName = 'DESK'; $s2.RemoteName = 'lap'
        [void]$Core::WriteConfig($s2, '3840,0,1920,1080,L@0,0,1920,1080')
        $layout = [IO.File]::ReadAllText($layoutPath)
        $edge = @{ Left = 'left'; Right = 'right'; Top = 'up'; Bottom = 'down' }[$side]; $opp = @{ Left = 'right'; Right = 'left'; Top = 'down'; Bottom = 'up' }[$side]
        Check "layout: other computer on the $side -> '$edge = lap' and back '$opp = DESK'" ($layout -match "DESK:\s*\r?\n\s*$edge = lap" -and $layout -match "lap:\s*\r?\n\s*$opp = DESK")
    }
    $ini = [IO.File]::ReadAllText($cfgPath)
    Check 'engine settings: server mode, names, both computers declared' ($ini -match '(?m)^coreMode=2' -and $ini -match '(?m)^computerName=DESK' -and $ini -match '(?m)^\[computer_DESK\]' -and $ini -match '(?m)^\[computer_lap\]')
    Check 'engine settings: portal quoted, owner process recorded' ($ini -match '(?m)^portal="3840,0,1920,1080,L@0,0,1920,1080"' -and $ini -match "(?m)^portalPid=$PID\b")
    Check 'engine settings: the server engine runs as the user (so it can read the clipboard)' ($ini -match '(?m)^\[daemon\]\s*\r?\n\s*elevate=false')
    Check 'engine settings: switching options written' ($ini -match '(?m)^enableSwitchDelay=true' -and $ini -match '(?m)^switchDelay=333')
    Check 'engine settings: layout file referenced with forward slashes' ($ini -match '(?m)^externalConfigFile="[A-Za-z]:/[^"\\]+layout\.conf"')
    $changed = $Core::WriteConfig($s2, '3840,0,1920,1080,L@0,0,1920,1080')
    Check 'writing identical settings reports "unchanged" (no needless engine restart)' (-not $changed)
    $s2.ComputerName = 'DE"SK ;x'; [void]$Core::WriteConfig($s2, $null)
    Check 'unsafe characters stripped from computer names' ([IO.File]::ReadAllText($cfgPath) -match '(?m)^computerName=DESKx\s*$')
    $client = [Activator]::CreateInstance($Settings); $client.Role = [Enum]::Parse((& $T 'DeskView.Role'), 'Client'); $client.ServerAddress = '10.0.0.10'; $client.ComputerName = 'lap'
    [void]$Core::WriteConfig($client, $null); $ini = [IO.File]::ReadAllText($cfgPath)
    Check 'client settings: client mode, server address, no portal, engine keeps admin rights' ($ini -match '(?m)^coreMode=1' -and $ini -match '(?m)^remoteHost=10\.0\.0\.10' -and $ini -notmatch 'portal=' -and $ini -notmatch 'elevate=false')
} finally { foreach ($p in $cfgPath, $layoutPath) { if ($saved.ContainsKey($p)) { [IO.File]::WriteAllText($p, $saved[$p]) } } }

# ---------------------------------------------------------------------------------------------- exit sides / monitors
$Engine = & $T 'DeskView.Engine'
$exitSides = $Engine.GetMethod('ExitSides', $bf)
# reflection call with raw .NET objects (PowerShell would otherwise pass its wrappers)
function Sides($rect, $list) { $a = New-Object 'object[]' 2; $a[0] = $rect; $a[1] = $list.PSObject.BaseObject; $exitSides.Invoke($null, $a) }
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
$none = New-Object 'System.Collections.Generic.List[System.Drawing.Rectangle]'
$first = $screens[0].Bounds; $last = $screens[-1].Bounds
$sFirst = Sides $first $none; $sLast = Sides $last $none
if ($screens.Count -ge 2) {
    Check "exit sides: left-most monitor only exits right ($sFirst)" ($sFirst -eq 'R')
    Check "exit sides: right-most monitor only exits left ($sLast)" ($sLast -eq 'L')
    $others = New-Object 'System.Collections.Generic.List[System.Drawing.Rectangle]'; $others.Add($screens[1].Bounds)
    Check 'exit sides: never into another picture (fallback when nothing is left)' ((Sides $first $others) -eq 'LRTB')
}
Check 'monitor lookup: 1 = left-most, DISPLAYn by name, unknown = none' ($Engine::ResolveMonitor('1') -eq ($screens[0].DeviceName -replace '^\\\\\.\\','') -and $Engine::ResolveMonitor('DISPLAY999') -eq $null -and $Engine::ResolveMonitor('99') -eq $null)

# ---------------------------------------------------------------------------------------------- screen numbering offered to the other computer
$shared = @(([DeskView.Tools]::SharedScreens()))
Check 'the main screen is always offered as screen 1 (then left to right)' ($shared[0].Primary -and (@($shared | Select -Skip 1 | % { $_.Bounds.X }) -join ',') -eq (@($shared | Select -Skip 1 | Sort-Object { $_.Bounds.X } | % { $_.Bounds.X }) -join ','))

# ---------------------------------------------------------------------------------------------- every screen can be captured
$outs = [DeskViewDxgi]::AllOutputs(); $names = @($outs | % Name)
$missing = @($screens | % { $_.DeviceName -replace '^\\\\\.\\', '' } | ? { $names -notcontains $_ })
Check "every monitor is found for capture, on whichever graphics adapter ($(($outs | % { "$($_.Name)@$($_.Adapter):$($_.Index)" }) -join ', '))" ($missing.Count -eq 0) "missing: $($missing -join ', ')"

# ---------------------------------------------------------------------------------------------- picture placement
$Media = & $T 'DeskView.Media'; $Player = & $T 'DeskView.Player'
$sFit = [Activator]::CreateInstance($Settings); $media = [Activator]::CreateInstance($Media, @($sFit))
$pl = [Activator]::CreateInstance($Player); $pl.Screen = $screens[0]; $pl.RemoteRes = [Nullable[System.Drawing.Size]](New-Object System.Drawing.Size 2560, 1080)
$r = $media.PictureRect($pl); $b = $screens[0].Bounds
$expH = [int][math]::Round(1080 * [math]::Min($b.Width / 2560.0, $b.Height / 1080.0))
Check "fit: an ultrawide picture is letterboxed on this monitor ($($r.Width)x$($r.Height))" ($r.Width -eq $b.Width -and [math]::Abs($r.Height - $expH) -le 1 -and $r.Y -gt $b.Y)
$sFit.Picture = 'Stretch'
Check 'stretch: the picture fills the monitor' ($media.PictureRect($pl) -eq $b)

# ---------------------------------------------------------------------------------------------- the picture is in front
# Windows ignores "always on top" for a player started in the background, so its picture could end up behind this
# computer's windows. Started exactly like the app starts players, it must end up inside a window that is on top.
$ffplay = (& $T 'DeskView.Tools')::Find('ffplay')
if ($ffplay) {
    $start = (& $T 'DeskView.Media').GetMethod('Start', $bf)
    $box = New-Object System.Drawing.Rectangle ($b.Right - 340), ($b.Bottom - 300), 320, 240
    $p = $start.Invoke($null, @($ffplay, "-hide_banner -loglevel error -noborder -left $($box.X) -top $($box.Y) -x 320 -y 240 -window_title DVQA-PICTURE -f lavfi -i testsrc=size=320x240:rate=30", $null))
    $w = [IntPtr]::Zero; for ($i = 0; $i -lt 100 -and $w -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 50; $w = [DeskViewPortal]::FindVisibleWindow($p.Id, 'DVQA-PICTURE') }
    $pictureHost = New-Object DeskViewPictureHost $box
    $adopted = $pictureHost.Adopt($w)
    for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
    $bmp = New-Object System.Drawing.Bitmap 320, 240; [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($box.X, $box.Y, 0, 0, $bmp.Size)
    $colours = @{}; for ($x = 5; $x -lt 320; $x += 20) { $c = $bmp.GetPixel($x, 60); $colours["$($c.R),$($c.G),$($c.B)"] = 1 }
    Check 'the picture is held by a window that is always on top' ($adopted -and $w -ne [IntPtr]::Zero -and [DeskViewPortal]::IsTopmost($pictureHost.Handle) -and $pictureHost.Holding)
    Check "the picture is what is on the screen there ($($colours.Count) colours of the test picture)" ($colours.Count -ge 6)
    try { $p.Kill() } catch { }
    for ($i = 0; $i -lt 20 -and $pictureHost.Holding; $i++) { Start-Sleep -Milliseconds 100 }
    Check 'the host notices when the player is gone' (-not $pictureHost.Holding)
    $pictureHost.Close()
}

# ---------------------------------------------------------------------------------------------- FFmpeg next to the app
# The app runs inside powershell.exe: the FFmpeg that setup puts next to the app must be found first, not one on PATH.
$fakeApp = Join-Path $env:TEMP "dv-app-ffmpeg-$PID"; New-Item -ItemType Directory -Force (Join-Path $fakeApp 'ffmpeg') | Out-Null
Set-Content (Join-Path $fakeApp 'ffmpeg\ffmpeg.exe') 'x'
$oldDir = $env:DESKVIEW_APPDIR; $env:DESKVIEW_APPDIR = $fakeApp
$found = (& $T 'DeskView.Tools')::Find('ffmpeg')
$env:DESKVIEW_APPDIR = $oldDir; [IO.Directory]::Delete($fakeApp, $true)
Check 'FFmpeg next to the app is used first (setup''s pinned build), not one on PATH' ($found -eq (Join-Path $fakeApp 'ffmpeg\ffmpeg.exe')) $found
# ---------------------------------------------------------------------------------------------- no video key in reports
# The video key is derived from the pairing code: it must never reach a file. FFREPORT wrote the whole command line
# (the SRT address with the passphrase) into %TEMP%, and ffmpeg repeats that address in its error messages.
$media0 = & $T 'DeskView.Media'
$red = $media0::Redact('Connection to srt://10.0.0.1:9000?mode=caller&passphrase=a4bb3eb444dc1abd9a87a8f9ffe1af16&pbkeylen=32 failed')
Check 'redact: the passphrase in an SRT address is removed, the rest kept' ($red -notmatch 'a4bb3eb4' -and $red -match 'passphrase=\*\*\*&pbkeylen=32') $red
Check 'redact: "-passphrase KEY" option form too' (($media0::Redact('-passphrase a4bb3eb444dc1abd9a87 -i x')) -notmatch 'a4bb3eb4')
$ffmpegExe = (& $T 'DeskView.Tools')::Find('ffmpeg')
if ($ffmpegExe) {
    $startR = $media0.GetMethod('StartReported', $bf)
    $secret = 'deadbeefcafe0123456789abcdef4242'
    [string]$rep = Join-Path $env:TEMP "dv-qa-report-$PID.log"
    # a real error that prints the address: nobody listens on this port
    $pR = $startR.Invoke($null, @([string]$ffmpegExe, "-hide_banner -loglevel info -nostats -i `"srt://127.0.0.1:9?mode=caller&connect_timeout=300&passphrase=$secret&pbkeylen=32`"", $null, $rep))
    [void]$pR.WaitForExit(10000); Start-Sleep -Milliseconds 300
    $txt = if (Test-Path $rep) { [IO.File]::ReadAllText($rep) } else { '' }
    Check 'report: written by the app, holds ffmpeg''s messages' ($txt -match 'srt://127\.0\.0\.1:9') ("{0} bytes" -f $txt.Length)
    Check 'report: no video key and no command line in it' ($txt -notmatch $secret -and $txt -notmatch 'Command line:')
    Remove-Item $rep -ErrorAction SilentlyContinue
}
# ---------------------------------------------------------------------------------------------- live without report text
# The player only writes the stream's size into its report while its status line is on (it is off: the report would
# grow ~7 MB an hour). A picture must count as live once the player shows it, sized as the other computer told us.
if ($ffplay) {
    $sLive = [Activator]::CreateInstance($Settings); $mLive = [Activator]::CreateInstance((& $T 'DeskView.Media'), @($sLive))
    $mLive.RemoteScreen = [Func[int, Nullable[System.Drawing.Rectangle]]] { param($n) if ($n -eq 2) { [Nullable[System.Drawing.Rectangle]](New-Object System.Drawing.Rectangle -5760, 0, 1920, 1080) } else { $null } }
    $small = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Width * $_.Bounds.Height })[0]
    $plL = [Activator]::CreateInstance((& $T 'DeskView.Player')); $plL.Key = 'QA'; $plL.Screen = $small; $plL.RemoteN = 2; $plL.Report = Join-Path $env:TEMP "dv-qa-noreport-$PID.log"
    $plL.P = $start.Invoke($null, @($ffplay, "-hide_banner -loglevel error -nostats -noborder -left $($small.Bounds.X) -top $($small.Bounds.Y) -x 320 -y 240 -window_title DeskView -f lavfi -i testsrc=size=320x240:rate=30", $null))
    $plL.LastStart = Get-Date
    $mLive.Players['QA'] = $plL
    $end = (Get-Date).AddSeconds(8); while ((Get-Date) -lt $end -and -not $plL.Live) { [void]$mLive.ServicePlayers('127.0.0.1'); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    Check 'a picture is live once shown, sized and placed as the other computer told (no report text needed)' ($plL.Live -and $plL.RemoteRect -eq '-5760,0,1920,1080' -and $plL.RemoteRes.Width -eq 1920) "live=$($plL.Live) rect=$($plL.RemoteRect)"
    $mLive.StopPlayers()
    Check 'stopping it closes the player and the window holding it' ($plL.P -eq $null -and $plL.Host -eq $null)
}
# ---------------------------------------------------------------------------------------------- smart screens' decisions
# Driven directly (no video, no guide windows): what the laptop reports -> which monitors show its screens.
$mons = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y } | % { $_.DeviceName -replace '^\\\\\.\\', '' })
if ($mons.Count -ge 3) {
    $smartHome = Join-Path $env:TEMP "dv-smart-$PID"; New-Item -ItemType Directory -Force $smartHome | Out-Null
    $oldHome = $env:DESKVIEW_HOME; $env:DESKVIEW_HOME = $smartHome; $oldNoMedia = $env:DESKVIEW_NOMEDIA; $env:DESKVIEW_NOMEDIA = '1'
    function NewSmartEngine {
        $st = $Settings::Load(); $st.Role = [Enum]::Parse((& $T 'DeskView.Role'), 'Server'); $st.SmartScreens = $true; $st.ShowGuide = $false; $st.PairCode = 'K7MPQ3XR'
        [Activator]::CreateInstance((& $T 'DeskView.Engine'), @($st))
    }
    $eng = NewSmartEngine
    $agentF = (& $T 'DeskView.Engine').GetField('agent', $bf); $svc = (& $T 'DeskView.Engine').GetMethod('ServiceSmartScreens', $bf)
    function Laptop($eng, $client, $occ) { $a = $agentF.GetValue($eng); $a.Client = $client; $a.OccupiedScreens = $occ }
    function Run($eng, $seconds) { $end = (Get-Date).AddSeconds($seconds); do { [void]$svc.Invoke($eng, @()); Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $end) }
    $S = { param($e) (& $T 'DeskView.Engine').GetField('S', $bf).GetValue($e) }
    function Shown($eng) { $sc = (& $S $eng).Screens; ($mons | % { if ($sc.ContainsKey($_)) { "$_=$($sc[$_])" } }) -join ' ' }

    Laptop $eng '10.0.0.2' '3,4'; Run $eng 0.5
    Check 'smart screens: windows on the laptop''s screens 3 and 4 show on monitors 2 and 3' ((Shown $eng) -eq "$($mons[1])=3 $($mons[2])=4") (Shown $eng)
    $eng.SetScreen($mons[1], 0); Run $eng 0.5
    Check 'smart screens: a monitor the user gives back is not taken again while its screen holds windows' ((Shown $eng) -eq "$($mons[2])=4") (Shown $eng)
    Laptop $eng '' ''; Run $eng 4
    Check 'smart screens: the laptop gone - the monitor it showed by itself is given back after its grace time' ((Shown $eng) -eq '') (Shown $eng)
    Laptop $eng '10.0.0.2' '3,4'; Run $eng 0.5
    Check 'smart screens: the laptop back - its windows show again, but the given-back monitor stays given back' ((Shown $eng) -eq "$($mons[2])=4") (Shown $eng)
    $eng2 = NewSmartEngine; Laptop $eng2 '10.0.0.2' '3,4'; Run $eng2 0.5
    Check 'smart screens: DeskView restarted - it still remembers what the user gave back' ((Shown $eng2) -eq "$($mons[2])=4") (Shown $eng2)
    Laptop $eng2 '10.0.0.2' '4'; Run $eng2 2
    Laptop $eng2 '10.0.0.2' '3,4'; Run $eng2 0.5
    Check 'smart screens: a short gap is not "emptied" (the give-back still holds)' ((Shown $eng2) -eq "$($mons[2])=4") (Shown $eng2)
    Laptop $eng2 '10.0.0.2' '4'; Run $eng2 5.5
    Laptop $eng2 '10.0.0.2' '3,4'; Run $eng2 0.5
    Check 'smart screens: once that screen really emptied (5 s), a window there shows by itself again' ((Shown $eng2) -eq "$($mons[1])=3 $($mons[2])=4") (Shown $eng2)
    $env:DESKVIEW_HOME = $oldHome; $env:DESKVIEW_NOMEDIA = $oldNoMedia; try { [IO.Directory]::Delete($smartHome, $true) } catch { }
}
"== app: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

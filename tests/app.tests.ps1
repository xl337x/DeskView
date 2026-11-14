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
Check 'code check accepts 8-12 valid characters, any case' ($Settings::IsValidPairCode('d4bbupsd') -and $Settings::IsValidPairCode('ABCDEFGH2345'))
Check 'code check rejects ambiguous / short / long codes' (-not $Settings::IsValidPairCode('ABCDEFG') -and -not $Settings::IsValidPairCode('ABCDEFGH0') -and -not $Settings::IsValidPairCode('ABCDEFGHJKMNP'))

# ---------------------------------------------------------------------------------------------- video key = script version
$s = [Activator]::CreateInstance($Settings); $s.PairCode = 'D4BBUPSD'
$sha = [Security.Cryptography.SHA256]::Create(); $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('DeskView-video-v2:D4BBUPSD'))
$scriptKey = -join ($h[0..15] | % { $_.ToString('x2') })
Check 'video key identical to the PowerShell DeskView (they interoperate)' ($s.VideoKey() -eq $scriptKey) "app=$($s.VideoKey()) script=$scriptKey"
$s.PairCode = ' d4bbupsd '
Check 'video key ignores case and spaces in the code' ($s.VideoKey() -eq $scriptKey)

# ---------------------------------------------------------------------------------------------- settings JSON round trip
$s2 = [Activator]::CreateInstance($Settings)
$s2.Role = [Enum]::Parse((& $T 'DeskView.Role'), 'Server'); $s2.RemoteName = 'leet'; $s2.Screens['DISPLAY1'] = 1; $s2.Screens['DISPLAY2'] = 2
$s2.SwitchDelayEnabled = $true; $s2.SwitchDelayMs = 333; $s2.RemoteSide = [Enum]::Parse((& $T 'DeskView.Side'), 'Bottom')
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$back = $ser.Deserialize($ser.Serialize($s2), $Settings)
Check 'settings survive a save/load round trip' ($back.RemoteName -eq 'leet' -and $back.Screens['DISPLAY2'] -eq 2 -and $back.SwitchDelayMs -eq 333 -and "$($back.RemoteSide)" -eq 'Bottom' -and "$($back.Role)" -eq 'Server')

# ---------------------------------------------------------------------------------------------- engine choice kept on update
$tmpHome = Join-Path $env:TEMP "dv-app-old-$PID"; New-Item -ItemType Directory -Force $tmpHome | Out-Null
Set-Content (Join-Path $tmpHome 'app.json') '{"Role":1,"PairCode":"D4BBUPSD","RemoteName":"leet"}' -Encoding UTF8
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
    $client = [Activator]::CreateInstance($Settings); $client.Role = [Enum]::Parse((& $T 'DeskView.Role'), 'Client'); $client.ServerAddress = '192.168.1.37'; $client.ComputerName = 'lap'
    [void]$Core::WriteConfig($client, $null); $ini = [IO.File]::ReadAllText($cfgPath)
    Check 'client settings: client mode, server address, no portal, engine keeps admin rights' ($ini -match '(?m)^coreMode=1' -and $ini -match '(?m)^remoteHost=192\.168\.1\.37' -and $ini -notmatch 'portal=' -and $ini -notmatch 'elevate=false')
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

"== app: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

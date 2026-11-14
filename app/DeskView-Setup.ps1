<#
  DeskView setup - the same command on both computers.

    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 [-Source <app folder>] [-PairCode CODE] [-Role Server|Client]
    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 -Uninstall

  Install:
    - Administrator approval only if something is missing: firewall rules for the local network only
      (UDP 9000-9009 video, TCP 9002 control, UDP 9010 finding the other computer), and the optional extras
      (-VirtualScreens N, -ClassicEngine).
    - Copies the app folder to %LOCALAPPDATA%\DeskView, gets FFmpeg (pinned build, checked), starts DeskView and
      starts it at every sign-in. DeskView runs from source inside Windows PowerShell: nothing is compiled here.
    - Pairing: the server makes a code (shown here and in the app); enter it on the client.
  Uninstall: stops DeskView, removes the startup entry, program folder, settings and firewall rules.
#>
param(
    [string]$Source,
    [string]$PairCode,
    [ValidateSet('', 'Server', 'Client')] [string]$Role = '',
    [string]$ServerAddress,                                        # client: the server's address (else found on the network)
    [ValidateRange(-1, 4)] [int]$VirtualScreens = -1,              # add N virtual screens (0 removes them; -1 leaves them)
    [switch]$ClassicEngine,                                        # also install the classic keyboard/mouse engine (optional)
    [switch]$Uninstall,
    [switch]$NoStart,             # tests: install only, don't start DeskView or add it to startup
    [switch]$SkipAdmin,           # tests: no administrator part
    [switch]$Elevated,            # internal: the part that needs administrator rights
    [switch]$RemoveRules          # internal: elevated part of uninstall
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# nobody to ask: a service, a scheduled task, or powershell -NonInteractive (Read-Host would wait forever or fail)
$canAsk = [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() | ? { $_ -match '^-noni' })
$installDir = if ($env:DESKVIEW_INSTALL) { $env:DESKVIEW_INSTALL } else { Join-Path $env:LOCALAPPDATA 'DeskView' }
$settingsDir = if ($env:DESKVIEW_HOME) { $env:DESKVIEW_HOME } else { Join-Path $env:APPDATA 'DeskView' }
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskView.lnk'
$rulesWanted = @(
    @{ Name = 'DeskView video (UDP 9000-9009)'; Protocol = 'UDP'; Port = '9000-9009' },
    @{ Name = 'DeskView control (TCP 9002)'; Protocol = 'TCP'; Port = '9002' },
    @{ Name = 'DeskView discovery (UDP 9010)'; Protocol = 'UDP'; Port = '9010' }
)
# FFmpeg: one pinned build (screen capture, SRT, GPU encoders, player), checked by its SHA256.
$ffName = 'ffmpeg-n9.0.2-57-gd838f9f9ae-win64-gpl-shared-9.0.zip'
$ffSha256 = 'f4e068477787394da18a44b27d3e2cb19e05b21495b836a4fd5a31958b608932'
$ffUrls = @("https://github.com/xl337x/DeskView/releases/download/deps-ffmpeg-9.0/$ffName",
            "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-11-13-12-43/$ffName")
# The optional classic engine's own names (installed only with -ClassicEngine).
$engineGuiExe = 'C:\Program Files\Deskflow\deskflow.exe'; $engineWingetId = 'Deskflow.Deskflow'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'This PC only allows restricted PowerShell (constrained language mode), so DeskView cannot run here.' -ForegroundColor Yellow
    Write-Host 'Ask IT to allow DeskView (or to sign it).'; exit 1
}

# ---- virtual screens (Virtual Display Driver, github.com/VirtualDrivers/Virtual-Display-Driver) -------------
# Extra screens Windows treats as real monitors: DeskView streams them like any other screen, so the other
# computer can show each on one of its monitors and windows can be dragged between them.
function Set-VirtualScreens([int]$count) {
    $cfgDir = 'C:\VirtualDisplayDriver'; $cfg = Join-Path $cfgDir 'vdd_settings.xml'
    $device = { Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ? { $_.FriendlyName -match 'Virtual Display' -or $_.HardwareID -match 'MttVDD' } }
    if ($count -eq 0) {
        $dev = & $device
        if ($dev) { $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue }
        Write-Host 'Virtual screens off.'; return $true
    }
    if (-not (& $device)) {
        Write-Host "Installing the virtual display driver ($count screen$(if ($count -gt 1) { 's' }))..."
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host 'winget is needed for the virtual display driver.'; return $false }
        winget install --id VirtualDrivers.Virtual-Display-Driver -e --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Host
    }
    $dev = & $device
    if (-not $dev) { Write-Host 'The virtual display driver did not install (managed PCs often block drivers).'; return $false }
    # The driver reads how many screens to make from its settings file: write it if it is missing.
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    if (Test-Path $cfg) { [xml]$x = Get-Content $cfg } else { [xml]$x = '<vdd_settings><monitors><count>1</count></monitors></vdd_settings>' }
    if (-not $x.vdd_settings.monitors) { $m = $x.CreateElement('monitors'); [void]$x.vdd_settings.AppendChild($m) }
    if ($x.vdd_settings.monitors.count -eq $null) { $c = $x.CreateElement('count'); [void]$x.vdd_settings.monitors.AppendChild($c) }
    $x.vdd_settings.monitors.count = [string]$count
    $x.Save($cfg)
    # Reload the driver so it creates the new number of screens.
    $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 2
    $dev | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Virtual screens: $count. Arrange them in Settings > System > Display (e.g. to the right of this screen)."
    $true
}

# ---- elevated parts ------------------------------------------------------------------------------------
if ($RemoveRules) { Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; exit 0 }
if ($Elevated) {
    Write-Host 'Firewall: allowing DeskView from the local network only (video, control, finding the other computer)...'
    Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    foreach ($r in $rulesWanted) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Protocol -LocalPort $r.Port -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    }
    $failed = 0
    if ($ClassicEngine -and -not (Test-Path $engineGuiExe)) {
        Write-Host 'Installing the classic keyboard/mouse engine...'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id $engineWingetId -e --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Host
        }
        if (-not (Test-Path $engineGuiExe)) { Write-Host 'The classic engine is NOT installed (DeskView works without it).'; $failed++ }
    }
    if ($VirtualScreens -ge 0) { if (-not (Set-VirtualScreens $VirtualScreens)) { $failed++ } }
    exit $failed
}

function Run-Elevated([string]$arguments) {
    $self = Join-Path $env:TEMP 'DeskView-Setup-elevated.ps1'
    Copy-Item $PSCommandPath $self -Force
    try { $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`" $arguments" }
    catch { Write-Warning 'Administrator approval was declined.'; return $false }
    $p.ExitCode -eq 0
}

function Stop-DeskView {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        ? { $_.ProcessId -ne $PID -and $_.CommandLine -match 'DeskView\.ps1' -and $_.CommandLine -notmatch 'Setup' } |
        % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process DeskView -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue   # an older exe build
    # Only DeskView's own streams (they use srt://), never unrelated FFmpeg jobs.
    Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe' OR Name='ffplay.exe'" | ? { $_.CommandLine -match 'srt://' } |
        % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---- uninstall -----------------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host '== DeskView uninstall ==' -ForegroundColor Cyan
    Stop-DeskView
    if (Test-Path $startupLink) { [IO.File]::Delete($startupLink) }
    foreach ($dir in $installDir, $settingsDir) { if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) } }
    if (-not $SkipAdmin -and (Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue)) {
        Write-Host 'Removing the firewall rules (a Windows prompt will appear)...'
        [void](Run-Elevated '-RemoveRules')
    }
    Write-Host 'DeskView removed.' -ForegroundColor Green
    exit 0
}

# ---- install -------------------------------------------------------------------------------------------
Write-Host '== DeskView setup ==' -ForegroundColor Cyan
if (-not $Source) { $Source = $PSScriptRoot }
if (-not (Test-Path (Join-Path $Source 'DeskView.ps1'))) { throw "No DeskView app in '$Source' (run install.ps1, or pass -Source <checkout>\app)." }

# 1. Administrator part - only when something is actually missing.
$rules = @(Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | % DisplayName)
$needAdmin = @($rulesWanted | ? { $rules -notcontains $_.Name }).Count -gt 0 -or $VirtualScreens -ge 0 -or ($ClassicEngine -and -not (Test-Path $engineGuiExe))
if ($SkipAdmin) { Write-Host 'Step 1/4: administrator part skipped.' }
elseif ($needAdmin) {
    Write-Host 'Step 1/4: administrator approval for the firewall rules (a Windows prompt will appear)...'
    $elevArgs = "-Elevated -VirtualScreens $VirtualScreens" + $(if ($ClassicEngine) { ' -ClassicEngine' })
    if (-not (Run-Elevated $elevArgs)) { Write-Warning 'The administrator part did not fully succeed (see above).' }
} else { Write-Host 'Step 1/4: firewall rules already in place.' }

# 2. Copy the app (the whole folder, so every file is from the same version; FFmpeg and old files handled below).
Write-Host "Step 2/4: installing to $installDir"
if (-not $NoStart) { Stop-DeskView }
New-Item -ItemType Directory -Force $installDir | Out-Null
$src = (Resolve-Path $Source).Path.TrimEnd('\'); $dst = (Resolve-Path $installDir).Path.TrimEnd('\')
if ($src -ne $dst) {
    # mirror, but keep the downloaded FFmpeg
    $null = robocopy $src $dst /MIR /XD ffmpeg /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "Copying DeskView failed (robocopy $LASTEXITCODE)." }
}

# FFmpeg: use one on PATH if it can do what DeskView needs (screen capture, SRT, ffplay), else the pinned build.
function Test-FFmpeg([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe) -or -not (Test-Path (Join-Path (Split-Path $exe) 'ffplay.exe'))) { return $false }
    $filters = & $exe -hide_banner -filters 2>$null | Out-String; $protocols = & $exe -hide_banner -protocols 2>$null | Out-String
    ($filters -match '\bddagrab\b') -and ($protocols -match '(?m)^\s*srt\s*$')
}
$ffDir = Join-Path $installDir 'ffmpeg'
$pathFF = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not (Test-FFmpeg $pathFF) -and -not (Test-FFmpeg (Join-Path $ffDir 'ffmpeg.exe'))) {
    Write-Host '        downloading FFmpeg (82 MB, once)...'
    $zip = Join-Path $env:TEMP $ffName; $ok = $false
    foreach ($u in $ffUrls) {
        try {
            (New-Object Net.WebClient).DownloadFile($u, $zip)
            if ((Get-FileHash $zip -Algorithm SHA256).Hash -eq $ffSha256) { $ok = $true; break }
            Write-Warning "FFmpeg from $u does not match its checksum - not used."
        } catch { Write-Warning "FFmpeg download from $u failed: $($_.Exception.Message)" }
    }
    if (-not $ok) { throw 'Could not get FFmpeg (download or checksum failed).' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $ffDir) { [IO.Directory]::Delete($ffDir, $true) }
    New-Item -ItemType Directory -Force $ffDir | Out-Null
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        # only what DeskView runs: ffmpeg, ffplay and their libraries
        foreach ($e in $z.Entries | ? { $_.FullName -match '/bin/[^/]+\.(exe|dll)$' -and $_.Name -ne 'ffprobe.exe' }) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $ffDir $e.Name), $true)
        }
    } finally { $z.Dispose() }
    [IO.File]::Delete($zip)
    if (-not (Test-FFmpeg (Join-Path $ffDir 'ffmpeg.exe'))) { throw 'FFmpeg was installed but cannot capture the screen or use SRT.' }
}

# 3. Role and pairing: handed to DeskView in setup.json, which it applies at its next start.
Write-Host 'Step 3/4: pairing'
New-Item -ItemType Directory -Force $settingsDir | Out-Null
function Get-KnownCode {
    foreach ($f in 'app.json', 'settings.json') {
        $p = Join-Path $settingsDir $f
        if (Test-Path $p) { try { $c = (Get-Content $p -Raw | ConvertFrom-Json).PairCode; if ($c) { return $c } } catch { } }
    }
    $null
}
$known = Get-KnownCode
if (-not $Role) {
    $knownRole = $null
    $p = Join-Path $settingsDir 'app.json'
    if (Test-Path $p) { try { $r = (Get-Content $p -Raw | ConvertFrom-Json).Role; if ($r -eq 1) { $knownRole = 'Server' } elseif ($r -eq 2) { $knownRole = 'Client' } } catch { } }
    if ($knownRole) { $Role = $knownRole }
    elseif (-not $canAsk) { throw 'Pass -Role Server or -Role Client (no one to ask).' }
    else {
        $isServerAnswer = (Read-Host '   Is this the computer whose keyboard and mouse you share (the SERVER)? [y/N]') -match '^[yY]'
        $Role = if ($isServerAnswer) { 'Server' } else { 'Client' }
        Write-Host '   Then set up the other computer the same way (as the other role).'
    }
}
$codePattern = '^[2-9A-HJKMNP-Z]{8,12}$'
if ($Role -eq 'Server') {
    if (-not $PairCode) { $PairCode = $known }
    if (-not $PairCode) {
        $alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; $bytes = New-Object byte[] 12
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
        $PairCode = -join ($bytes | % { $alphabet[$_ % $alphabet.Length] })
    }
    Write-Host ''
    Write-Host "   This computer is the SERVER. Pairing code:  $PairCode" -ForegroundColor Green
    Write-Host '   Enter it when installing on the other computer (it is also shown in the DeskView app).'
} else {
    if (-not $PairCode) { $PairCode = $known }
    while (-not $PairCode -or $PairCode.Trim().ToUpper() -notmatch $codePattern) {
        if ($PairCode) { Write-Host "   '$PairCode' is not a DeskView pairing code (8-12 letters/digits, as shown on the server)." -ForegroundColor Yellow }
        if (-not $canAsk) { throw 'Pass the pairing code with -PairCode (no one to ask).' }
        $PairCode = Read-Host '   This computer is a CLIENT. Enter the pairing code shown on the server'
    }
}
$handoff = [ordered]@{ Role = $Role; PairCode = $PairCode.Trim().ToUpper() }
if ($ServerAddress) { $handoff.ServerAddress = $ServerAddress }
$handoff | ConvertTo-Json | Set-Content (Join-Path $settingsDir 'setup.json') -Encoding UTF8

# 4. Start now and at every sign-in.
$app = Join-Path $installDir 'DeskView.ps1'
if ($NoStart) { Write-Host 'Step 4/4: not started (-NoStart).'; exit 0 }
Write-Host 'Step 4/4: starting DeskView and adding it to startup'
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($startupLink); $sc.TargetPath = 'powershell.exe'
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`" -Tray"; $sc.WindowStyle = 7; $sc.Description = 'DeskView'; $sc.Save()
Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`"" -WindowStyle Hidden
Write-Host ''
Write-Host 'Done. DeskView lives in the tray (bottom-right).' -ForegroundColor Green
if ($Role -eq 'Server') { Write-Host '   Push the mouse off the edge facing the other computer to work on it; Ctrl+Alt+1..9 shows it on a monitor, Ctrl+Alt+0 hides it.' }
else { Write-Host "   Ctrl+Alt+1..9 shows the server's monitor 1..9 here and lets you control it, Ctrl+Alt+0 comes back." }

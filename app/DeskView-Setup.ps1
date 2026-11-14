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
    [ValidateSet('Left', 'Right')] [string]$VirtualScreensSide = 'Left',   # where they sit next to this computer's own screens
    [switch]$ClassicEngine,
    [string]$FFmpegZip,                                            # the pinned FFmpeg zip, for a PC without internet access                                        # also install the classic keyboard/mouse engine (optional)
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

# Asked once per laptop: an update (or a reinstall) leaves the extra screens as they are and doesn't ask again.
# The answer counts as given only once it worked ("<n> ok"), so a declined prompt or a blocked driver is asked again.
$extraScreensAsked = Join-Path $settingsDir 'extra-screens-chosen.txt'
function Test-VirtualScreenDevice {
    [bool](Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue | ? { $_.Status -eq 'OK' -and ($_.FriendlyName -match 'Virtual Display' -or ($_.HardwareID -join ' ') -match 'MttVDD') })
}
function Test-ExtraScreensChosen {
    if ((Test-Path $extraScreensAsked) -and ((Get-Content $extraScreensAsked -Raw) -match 'ok')) { return $true }
    Test-VirtualScreenDevice
}
function Ask-ExtraScreens {
    Write-Host 'This laptop''s windows can be dragged onto the server''s monitors through extra screens (one per monitor).'
    $answer = Read-Host '   How many extra screens should this laptop get? (0-4, Enter = 3)'
    if ($answer -match '^[0-4]$') { [int]$answer } else { 3 }
}

# ---- virtual screens (Virtual Display Driver, github.com/VirtualDrivers/Virtual-Display-Driver) -------------
# Extra screens Windows treats as real monitors: DeskView streams them like any other screen, so the other
# computer can show each on one of its monitors and windows can be dragged between them.
function Set-VirtualScreens([int]$count) {
    $cfgDir = 'C:\VirtualDisplayDriver'; $cfg = Join-Path $cfgDir 'vdd_settings.xml'
    $device = { Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ? { $_.FriendlyName -match 'Virtual Display' -or ($_.HardwareID -join ' ') -match 'MttVDD' } }
    if ($count -eq 0) {
        $dev = & $device
        if ($dev) { $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue }
        Write-Host 'Virtual screens off.'; return $true
    }
    # The winget package only unpacks the driver: find it, trust its signer (Windows can't ask in a background
    # install), put it in the driver store and create the device.
    if (-not (& $device)) {
        Write-Host "Installing the virtual display driver ($count screen$(if ($count -gt 1) { 's' }))..."
        $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'VirtualDrivers.Virtual-Display-Driver*' -ErrorAction SilentlyContinue | Select -First 1
        if (-not $pkg) {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host 'winget is needed for the virtual display driver.'; return $false }
            winget install --id VirtualDrivers.Virtual-Display-Driver -e --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity | Out-Host
            $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'VirtualDrivers.Virtual-Display-Driver*' -ErrorAction SilentlyContinue | Select -First 1
        }
        if (-not $pkg) { Write-Host 'The virtual display driver package was not found.'; return $false }
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x86' }   # the package's x64 build sits in "x86"
        $drv = Join-Path $pkg.FullName "SignedDrivers\$arch\VDD"; $inf = Join-Path $drv 'MttVDD.inf'
        $sig = Get-AuthenticodeSignature (Join-Path $drv 'mttvdd.cat')
        if ($sig.Status -ne 'Valid') { Write-Host "The virtual display driver's signature is not valid ($($sig.Status)) - not installed."; return $false }
        $store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
        $store.Open('ReadWrite'); $store.Add($sig.SignerCertificate); $store.Close()
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        Set-Content (Join-Path $cfgDir 'deskview-cert.txt') $sig.SignerCertificate.Thumbprint   # so uninstall removes exactly this trust again
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        if (-not (Test-Path $cfg)) { Copy-Item (Join-Path $drv 'vdd_settings.xml') $cfg }
        pnputil /add-driver $inf /install | Out-Null
        if (-not (& $device)) { & (Join-Path $pkg.FullName 'Dependencies\devcon.exe') install $inf 'Root\MttVDD' | Out-Null }
        Start-Sleep 3
    }
    $dev = & $device
    if (-not $dev) { Write-Host 'The virtual display driver did not install (managed PCs often block drivers).'; return $false }
    # How many screens, and render them on the first graphics adapter: that is the one screen capture and the
    # GPU encoder use, so the frames never leave the graphics chip (a second GPU would need copies).
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    if (Test-Path $cfg) { [xml]$x = Get-Content $cfg } else { [xml]$x = '<vdd_settings><monitors><count>1</count></monitors><gpu><friendlyname>default</friendlyname></gpu></vdd_settings>' }
    $x.vdd_settings.monitors.count = [string]$count
    try { Add-Type -Path (Join-Path $PSScriptRoot 'DeskView-Dxgi.cs') -ErrorAction Stop; $gpu = [DeskViewDxgi]::FirstAdapterName() } catch { $gpu = $null }
    if ($gpu -and $x.vdd_settings.gpu) { $x.vdd_settings.gpu.friendlyname = $gpu }
    $x.Save($cfg)
    # Reload the driver so it creates the screens.
    $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 2
    $dev | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 4
    Write-Host "Virtual screens: $count (on $(if ($gpu) { $gpu } else { 'the default adapter' }))."
    $true
}

# Not elevated, as the signed-in user: switch the desktop onto the virtual screens and put them, 1920x1080 each, in a
# row to the right of this computer's own screens.
function Arrange-VirtualScreens {
    try {
        Add-Type -Path (Join-Path $PSScriptRoot 'DeskView-Displays.cs') -ErrorAction Stop
        if ([DeskViewDisplays]::VirtualScreens().Count -eq 0) { & "$env:WINDIR\System32\DisplaySwitch.exe" /extend; Start-Sleep 6 }
        [DeskViewDisplays]::Arrange(1920, 1080, ($VirtualScreensSide -eq 'Left')) | % { Write-Host "        $_" }
    } catch { Write-Warning "Arranging the virtual screens failed: $($_.Exception.Message) - use Settings > System > Display." }
}
# ---- elevated parts ------------------------------------------------------------------------------------
if ($RemoveRules) {
    Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    # the extra screens: without DeskView they are invisible monitors where windows and the pointer get lost.
    # Only if DeskView installed them (its marker file): someone's own virtual display driver is left alone.
    $cfgDir = 'C:\VirtualDisplayDriver'
    $thumbFile = Join-Path $cfgDir 'deskview-cert.txt'
    if (Test-Path $thumbFile) {
        Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ? { ($_.HardwareID -join ' ') -match 'MttVDD' } |
            % { pnputil /remove-device $_.InstanceId | Out-Null }
        $drivers = (pnputil /enum-drivers | Out-String) -split '\r?\n\s*\r?\n'
        foreach ($d in $drivers | ? { $_ -match '(?i)mttvdd\.inf' }) { if ($d -match '(oem\d+\.inf)') { pnputil /delete-driver $Matches[1] /uninstall /force | Out-Null } }
        $thumb = (Get-Content $thumbFile -Raw).Trim()
        $store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine'); $store.Open('ReadWrite')
        $store.Certificates | ? { $_.Thumbprint -eq $thumb } | % { $store.Remove($_) }; $store.Close()
        [IO.Directory]::Delete($cfgDir, $true)
    } elseif (Test-Path $cfgDir) { Write-Host 'A virtual display driver DeskView did not install was left in place.' }
    exit 0
}
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
    Copy-Item (Join-Path $PSScriptRoot 'DeskView-Dxgi.cs') (Join-Path $env:TEMP 'DeskView-Dxgi.cs') -Force -ErrorAction SilentlyContinue   # used by the elevated part
    try { $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`" $arguments" }
    catch { Write-Warning 'Administrator approval was declined.'; return $false }
    $p.ExitCode -eq 0
}

# Stops the DeskView of THIS install only (a test install into another folder must never stop the real one).
# Its video processes stop with it (they are tied to it with a job object).
function Stop-DeskView {
    $mine = [regex]::Escape((Join-Path $installDir 'DeskView.ps1'))
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        ? { $_.ProcessId -ne $PID -and $_.CommandLine -match $mine } |
        % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $env:DESKVIEW_INSTALL) {
        # the real install: also an old .exe build, the old tray script, and streams they may have left behind
        Get-Process DeskView -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.ProcessId -ne $PID -and $_.CommandLine -match 'DeskView\.ps1' -and $_.CommandLine -notmatch 'Setup|tests' -and $_.CommandLine -match [regex]::Escape($env:LOCALAPPDATA) } |
            % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

# ---- uninstall -----------------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host '== DeskView uninstall ==' -ForegroundColor Cyan
    Stop-DeskView
    if (Test-Path $startupLink) { [IO.File]::Delete($startupLink) }
    foreach ($dir in $installDir, $settingsDir) { if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) } }
    # an older DeskView started itself from the Run key
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DeskView -ErrorAction SilentlyContinue
    $vdd = Test-Path 'C:\VirtualDisplayDriver\deskview-cert.txt'   # extra screens DeskView installed
    if (-not $SkipAdmin -and ((Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue) -or $vdd)) {
        Write-Host 'Removing the firewall rules and extra screens (a Windows prompt will appear)...'
        [void](Run-Elevated '-RemoveRules')
    }
    Write-Host 'DeskView removed.' -ForegroundColor Green
    exit 0
}

# ---- install -------------------------------------------------------------------------------------------
# Order matters: every question and every download happens while the old DeskView keeps running; only then is it
# stopped, updated and started again - and started again even when something fails on the way.
Write-Host '== DeskView setup ==' -ForegroundColor Cyan
if (-not $Source) { $Source = $PSScriptRoot }
if (-not (Test-Path (Join-Path $Source 'DeskView.ps1'))) { throw "No DeskView app in '$Source' (run install.ps1, or pass -Source <checkout>\app)." }

# 1. Role and pairing.
New-Item -ItemType Directory -Force $settingsDir | Out-Null
# DeskView's settings, else the copy it keeps from the save before (a file cut short must not cost the pairing)
function Read-AppJson {
    foreach ($f in 'app.json', 'app.json.bak') {
        $p = Join-Path $settingsDir $f
        if (Test-Path $p) { try { $o = Get-Content $p -Raw | ConvertFrom-Json; if ($o) { return $o } } catch { } }
    }
    $null
}
$appJson = Read-AppJson
$known = if ($appJson -and $appJson.PairCode) { $appJson.PairCode } else { $null }
if (-not $known) {
    $p = Join-Path $settingsDir 'settings.json'   # the older script version's settings
    if (Test-Path $p) { try { $known = (Get-Content $p -Raw | ConvertFrom-Json).PairCode } catch { } }
}
$knownRole = $null
if ($appJson) { if ($appJson.Role -eq 1) { $knownRole = 'Server' } elseif ($appJson.Role -eq 2) { $knownRole = 'Client' } }
if ($Role -and $knownRole -and $Role -ne $knownRole) {
    # a server's own code is not the code of the server a client must join (and the other way round)
    Write-Host "   Role changed ($knownRole -> $Role): the old pairing is replaced."
    $known = $null
}
if (-not $Role) {
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
} else {
    if (-not $PairCode) { $PairCode = $known }
    while (-not $PairCode -or $PairCode.Trim().ToUpper() -notmatch $codePattern) {
        if ($PairCode) { Write-Host "   '$PairCode' is not a DeskView pairing code (8-12 letters/digits, as shown on the server)." -ForegroundColor Yellow }
        if (-not $canAsk) { throw 'Pass the pairing code with -PairCode (no one to ask).' }
        $PairCode = Read-Host '   This computer is a CLIENT. Enter the pairing code shown on the server'
    }
}

# A laptop's windows can only go onto the other computer's monitors through extra (virtual) screens: offer them.
if ($VirtualScreens -lt 0 -and $Role -eq 'Client' -and $canAsk -and -not $SkipAdmin -and -not (Test-ExtraScreensChosen)) {
    $VirtualScreens = Ask-ExtraScreens
}

# 2. Administrator part - only when something is actually missing.
$warnings = @()
$rules = @(Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | % DisplayName)
$wantScreens = $VirtualScreens -gt 0 -or ($VirtualScreens -eq 0 -and (Test-VirtualScreenDevice))
$needAdmin = @($rulesWanted | ? { $rules -notcontains $_.Name }).Count -gt 0 -or $wantScreens -or ($ClassicEngine -and -not (Test-Path $engineGuiExe))
if ($SkipAdmin) { Write-Host 'Step 1/4: administrator part skipped.' }
elseif ($needAdmin) {
    Write-Host 'Step 1/4: administrator approval for the firewall rules (a Windows prompt will appear)...'
    $vsArg = if ($wantScreens) { $VirtualScreens } else { -1 }
    $elevArgs = "-Elevated -VirtualScreens $vsArg" + $(if ($ClassicEngine) { ' -ClassicEngine' })
    if (Run-Elevated $elevArgs) {
        if ($VirtualScreens -ge 0) { Set-Content $extraScreensAsked "$VirtualScreens ok" }
        if ($VirtualScreens -gt 0) { Arrange-VirtualScreens }
    } else {
        Write-Warning 'The administrator part did not fully succeed (see above).'
        if ($VirtualScreens -gt 0) { $warnings += 'Extra screens were NOT added - run setup again to retry.' }
    }
} else {
    Write-Host 'Step 1/4: firewall rules already in place.'
    if ($VirtualScreens -eq 0) { Set-Content $extraScreensAsked '0 ok' }   # "none" needs nothing installed
}

# 3. FFmpeg: always the pinned, checksum-checked build next to the app (a different FFmpeg on PATH may lack what
# DeskView needs, or be updated or removed later). Prepared beside the running app, swapped in below.
function Test-FFmpeg([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe) -or -not (Test-Path (Join-Path (Split-Path $exe) 'ffplay.exe'))) { return $false }
    $filters = & $exe -hide_banner -filters 2>$null | Out-String; $protocols = & $exe -hide_banner -protocols 2>$null | Out-String
    ($filters -match '\bddagrab\b') -and ($protocols -match '(?m)^\s*srt\s*$')
}
New-Item -ItemType Directory -Force $installDir | Out-Null
$ffDir = Join-Path $installDir 'ffmpeg'; $ffNew = Join-Path $installDir 'ffmpeg.new'; $ffStamp = 'deskview-pinned.txt'
$ffCurrent = (Test-Path (Join-Path $ffDir $ffStamp)) -and ((Get-Content (Join-Path $ffDir $ffStamp) -Raw).Trim() -eq $ffName) -and (Test-FFmpeg (Join-Path $ffDir 'ffmpeg.exe'))
if (-not $ffCurrent) {
    Write-Host 'Step 2/4: getting FFmpeg (pinned build, checked)...'
    # a copy kept from an earlier setup (or -FFmpegZip for a PC without internet) is used when its checksum matches
    $zip = if ($FFmpegZip) { $FFmpegZip } else { Join-Path $env:TEMP $ffName }
    $ok = (Test-Path $zip) -and ((Get-FileHash $zip -Algorithm SHA256).Hash -eq $ffSha256)
    if (-not $ok -and $FFmpegZip) { throw "'$FFmpegZip' is not the FFmpeg build DeskView needs ($ffName, checksum mismatch)." }
    if (-not $ok) {
        Write-Host '        downloading (82 MB, once)...'
        try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }   # company proxies
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        foreach ($u in $ffUrls) {
            try {
                (New-Object Net.WebClient).DownloadFile($u, $zip)
                if ((Get-FileHash $zip -Algorithm SHA256).Hash -eq $ffSha256) { $ok = $true; break }
                Write-Warning "FFmpeg from $u does not match its checksum - not used."
            } catch { Write-Warning "FFmpeg download from $u failed: $($_.Exception.Message)" }
        }
    }
    if (-not $ok) { throw "Could not get FFmpeg (download or checksum failed). Download $ffName from $($ffUrls[0]) and run setup with -FFmpegZip <that file>. DeskView was not changed." }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $ffNew) { [IO.Directory]::Delete($ffNew, $true) }
    New-Item -ItemType Directory -Force $ffNew | Out-Null
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        # only what DeskView runs: ffmpeg, ffplay and their libraries
        foreach ($e in $z.Entries | ? { $_.FullName -match '/bin/[^/]+\.(exe|dll)$' -and $_.Name -ne 'ffprobe.exe' }) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $ffNew $e.Name), $true)
        }
    } finally { $z.Dispose() }
    if (-not (Test-FFmpeg (Join-Path $ffNew 'ffmpeg.exe'))) { [IO.Directory]::Delete($ffNew, $true); throw 'FFmpeg cannot capture the screen or use SRT on this PC. DeskView was not changed.' }
    Set-Content (Join-Path $ffNew $ffStamp) $ffName
} else {
    Write-Host 'Step 2/4: FFmpeg already in place.'
    if (Test-Path $ffNew) { try { [IO.Directory]::Delete($ffNew, $true) } catch { } }   # a leftover from an interrupted setup
}

# 4. Stop, update and start again. If anything fails here, whatever DeskView is in place is started again anyway.
Write-Host "Step 3/4: installing to $($installDir.Replace($env:LOCALAPPDATA, '%LOCALAPPDATA%'))"
$app = Join-Path $installDir 'DeskView.ps1'
if (-not $NoStart) { Stop-DeskView }
try {
    $src = (Resolve-Path $Source).Path.TrimEnd('\'); $dst = (Resolve-Path $installDir).Path.TrimEnd('\')
    if ($src -ne $dst) {
        # mirror, but keep FFmpeg
        $null = robocopy $src $dst /MIR /XD ffmpeg ffmpeg.new ffmpeg.old /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw "Copying DeskView failed (robocopy $LASTEXITCODE)." }
    }
    if (Test-Path $ffNew) {
        # whole folders are renamed (a rename fails as a whole, leaving everything as it was): the old FFmpeg moves
        # aside, the new one moves in, and the old one comes back if the new one can't be put in place
        $ffOld = "$ffDir.old"
        if (Test-Path $ffOld) { try { [IO.Directory]::Delete($ffOld, $true) } catch { } }
        if (Test-Path $ffDir) {
            for ($i = 0; $i -lt 10 -and (Test-Path $ffDir); $i++) { try { [IO.Directory]::Move($ffDir, $ffOld) } catch { Start-Sleep -Milliseconds 500 } }   # its players may take a moment to exit
            if (Test-Path $ffDir) { throw "The old FFmpeg in $ffDir is still in use - close DeskView and run setup again." }
        }
        # the virus scanner may still be reading the new files for a moment
        for ($i = 0; $i -lt 20 -and (Test-Path $ffNew); $i++) { try { [IO.Directory]::Move($ffNew, $ffDir) } catch { Start-Sleep -Milliseconds 500 } }
        if ((Test-Path $ffNew) -or -not ((Test-Path (Join-Path $ffDir $ffStamp)) -and (Test-FFmpeg (Join-Path $ffDir 'ffmpeg.exe')))) {
            if (Test-Path $ffDir) { try { [IO.Directory]::Delete($ffDir, $true) } catch { } }
            if (Test-Path $ffOld) { [IO.Directory]::Move($ffOld, $ffDir) }
            throw "Could not put the new FFmpeg in place ($ffDir) - the previous one is kept."
        }
        try { [IO.Directory]::Delete($ffOld, $true) } catch { }
    }
    # role and pairing are handed to DeskView in setup.json, which it applies at its next start
    $handoff = [ordered]@{ Role = $Role; PairCode = $PairCode.Trim().ToUpper() }
    if ($ServerAddress) { $handoff.ServerAddress = $ServerAddress }
    $handoff | ConvertTo-Json | Set-Content (Join-Path $settingsDir 'setup.json') -Encoding UTF8
} finally {
    if (-not $NoStart -and (Test-Path $app)) {
        Write-Host 'Step 4/4: starting DeskView and adding it to startup'
        Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`"" -WindowStyle Hidden
        try {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($startupLink); $sc.TargetPath = 'powershell.exe'
            $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`" -Tray"; $sc.WindowStyle = 7; $sc.Description = 'DeskView'; $sc.Save()
        } catch { Write-Warning "Could not add DeskView to startup: $($_.Exception.Message)" }
    }
}
if ($NoStart) { Write-Host 'Step 4/4: not started (-NoStart).' }
Write-Host ''
if ($Role -eq 'Server') {
    Write-Host "   This computer is the SERVER. Pairing code:  $($PairCode.Trim().ToUpper())" -ForegroundColor Green
    Write-Host '   Enter it when installing on the other computer (it is also shown in the DeskView app).'
}
foreach ($w in $warnings) { Write-Host "   $w" -ForegroundColor Yellow }
if ($NoStart) { exit 0 }
if ($warnings) { Write-Host 'Done, with the warnings above. DeskView lives in the tray (bottom-right).' -ForegroundColor Yellow }
else { Write-Host 'Done. DeskView lives in the tray (bottom-right).' -ForegroundColor Green }
if ($Role -eq 'Server') { Write-Host '   Push the mouse off the edge facing the other computer to work on it; Ctrl+Alt+1..9 shows it on a monitor, Ctrl+Alt+0 hides it.' }
else { Write-Host "   Ctrl+Alt+1..9 shows the server's monitor 1..9 here and lets you control it, Ctrl+Alt+0 comes back." }

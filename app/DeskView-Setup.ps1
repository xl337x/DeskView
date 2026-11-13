<#
  DeskView setup - the same command on both machines.

    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 [-Source <folder | https://.../app>] [-PairCode CODE]
    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 -Uninstall

  Install:
    - Administrator approval only if something is missing: two firewall rules (local network only:
      UDP 9000-9009 video, TCP 9002 control) and the keyboard/mouse engine.
    - Copies DeskView to %LOCALAPPDATA%\DeskView, starts it, and starts it at every sign-in.
    - Pairing: the server gets a code (shown here and in its tray menu); enter it on the client.
  Uninstall: stops DeskView, removes the startup entry, program folder, settings and firewall rules.
#>
param(
    [string]$Source,
    [string]$PairCode,
    [switch]$Uninstall,
    [ValidateSet('', 'Server', 'Client')] [string]$Role = '',   # only needed if the engine was never set up on this machine
    [ValidateRange(-1, 4)] [int]$VirtualScreens = -1,              # add N virtual screens (0 removes them; -1 leaves them as they are)
    [switch]$Elevated,            # internal: the part that needs administrator rights
    [switch]$RemoveRules          # internal: elevated part of uninstall
)
$ErrorActionPreference = 'Stop'
$files = 'DeskView.ps1', 'DeskView-Portal.cs', 'DeskView-Input.cs', 'DeskView-Dxgi.cs', 'DeskView-Setup.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'DeskView'
$settingsDir = Join-Path $env:APPDATA 'DeskView'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskView.lnk'
$videoPorts = '9000-9009'; $controlPort = 9002      # one video port per screen (screen n = 9000+n-1)
$defaultSource = 'https://raw.githubusercontent.com/xl337x/DeskView/main/app'
# Engine identifiers: the installed keyboard/mouse engine's own names (until it is rebuilt under the DeskView name).
$engineGuiExe = 'C:\Program Files\Deskflow\deskflow.exe'; $engineIni = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'
$engineWingetId = 'Deskflow.Deskflow'; $engineReleasesApi = 'https://api.github.com/repos/deskflow/deskflow/releases/latest'

# ---- virtual screens (Virtual Display Driver, github.com/VirtualDrivers/Virtual-Display-Driver) -------------
# Extra screens for this machine that Windows treats as real monitors: DeskView streams them like any other
# screen, so the other machine can show each on one of its monitors and windows can be dragged between them.
function Set-VirtualScreens([int]$count) {
    $cfgDir = 'C:\VirtualDisplayDriver'; $cfg = Join-Path $cfgDir 'vdd_settings.xml'
    $device = { Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ? { $_.FriendlyName -match 'Virtual Display' -or $_.HardwareID -match 'MttVDD' } }
    if ($count -gt 0 -and -not (& $device)) {
        Write-Host "Installing the virtual display driver ($count screen$(if ($count -gt 1) { 's' }))..."
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host 'winget is needed for the virtual display driver.'; return $false }
        winget install --id VirtualDrivers.Virtual-Display-Driver -e --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Host
    }
    $dev = & $device
    if ($count -gt 0 -and -not $dev) { Write-Host 'The virtual display driver did not install.'; return $false }
    if (-not $dev) { return $true }
    if (Test-Path $cfg) {
        [xml]$x = Get-Content $cfg
        if ($count -eq 0) { $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue; Write-Host 'Virtual screens off.'; return $true }
        $x.vdd_settings.monitors.count = [string]$count
        $x.Save($cfg)
    }
    # Reload the driver so it creates the new number of screens.
    $dev | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 2
    $dev | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Virtual screens: $count. Arrange them in Settings > System > Display (e.g. to the right of the laptop screen)."
    $true
}

# ---- elevated parts ------------------------------------------------------------------------------------
if ($RemoveRules) { Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; exit 0 }
if ($Elevated) {
    Write-Host 'Firewall: allowing DeskView video (UDP 9000-9009) and control (TCP 9002) from the local network...'
    Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'DeskView video (UDP 9000-9009)' -Direction Inbound -Protocol UDP -LocalPort $videoPorts -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'DeskView control (TCP 9002)' -Direction Inbound -Protocol TCP -LocalPort $controlPort -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    $failed = 0
    if (-not (Test-Path $engineGuiExe)) {
        Write-Host 'Installing the keyboard/mouse engine...'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            # --source winget: on fresh machines the msstore source can fail and abort the whole install
            winget install --id $engineWingetId -e --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Host
        }
        if (-not (Test-Path $engineGuiExe)) {
            # No winget (or it failed): the engine's installer straight from its GitHub releases.
            try {
                $rel = Invoke-RestMethod $engineReleasesApi -UseBasicParsing
                $asset = $rel.assets | ? { $_.name -match 'win.*x64.*\.msi$' } | Select -First 1
                $msi = Join-Path $env:TEMP $asset.name
                Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
                $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
                Write-Host "Engine $($rel.tag_name) installer exit code $($p.ExitCode)"
            } catch { Write-Host "Engine download failed: $_" }
        }
        if (-not (Test-Path $engineGuiExe)) { Write-Host 'The keyboard/mouse engine is NOT installed.'; $failed++ }
    }
    if ($VirtualScreens -ge 0) { if (-not (Set-VirtualScreens $VirtualScreens)) { $failed++ } }
    exit $failed
}

function Run-Elevated([string]$switchName) {
    $self = Join-Path $env:TEMP 'DeskView-Setup-elevated.ps1'
    Copy-Item $PSCommandPath $self -Force
    try { $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -$switchName" }
    catch { Write-Warning 'Administrator approval was declined.'; return $false }
    $p.ExitCode -eq 0
}

function Stop-DeskView {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        ? { $_.ProcessId -ne $PID -and $_.CommandLine -match 'DeskView(-Control|-Sender|-Receiver)?\.ps1' -and $_.CommandLine -notmatch 'Setup' } |
        % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # Only DeskView's own streams (they use srt://), never unrelated FFmpeg jobs.
    Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe' OR Name='ffplay.exe'" | ? { $_.CommandLine -match 'srt://' } |
        % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---- uninstall -----------------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host '== DeskView uninstall ==' -ForegroundColor Cyan
    Stop-DeskView
    if (Test-Path $startupLink) { [IO.File]::Delete($startupLink) }
    # Give the engine its own settings back: no portal, and the screen layout from before DeskView.
    $ini = $engineIni
    if (Test-Path $ini) {
        $text = [IO.File]::ReadAllText($ini) -replace '(?m)^portal(Pid)?=.*\r?\n?', ''
        $backup = Join-Path $settingsDir 'engine-layout-backup.json'
        if (Test-Path $backup) {
            $b = Get-Content $backup -Raw | ConvertFrom-Json
            if ($null -ne $b.Content) { [IO.File]::WriteAllText($b.ServerConf, $b.Content) }
            if (-not $b.ExternalConfig) { $text = $text -replace '(?m)^externalConfig=true', 'externalConfig=false' }
        }
        [IO.File]::WriteAllText($ini, $text, (New-Object Text.UTF8Encoding $false))
    }
    foreach ($dir in $installDir, $settingsDir) { if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) } }
    if (Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue) {
        Write-Host 'Removing the firewall rules (a Windows prompt will appear)...'
        [void](Run-Elevated 'RemoveRules')
    }
    Write-Host 'DeskView removed. The keyboard/mouse engine and FFmpeg were left in place.' -ForegroundColor Green
    exit 0
}

# ---- install -------------------------------------------------------------------------------------------
Write-Host '== DeskView setup ==' -ForegroundColor Cyan
if (-not $Source) { $Source = if (Test-Path (Join-Path $PSScriptRoot 'DeskView.ps1')) { $PSScriptRoot } else { $defaultSource } }

# 1. Administrator part - only when something is actually missing (firewall rules, engine).
$rules = @(Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | % DisplayName)
$needAdmin = ($rules -notcontains 'DeskView video (UDP 9000-9009)') -or ($rules -notcontains 'DeskView control (TCP 9002)') -or
             -not (Test-Path $engineGuiExe) -or $VirtualScreens -ge 0
if ($needAdmin) {
    Write-Host 'Step 1/4: administrator approval for firewall rules / keyboard-mouse engine (a Windows prompt will appear)...'
    if (-not (Run-Elevated "Elevated -VirtualScreens $VirtualScreens")) { Write-Warning 'The administrator part did not fully succeed (see above) - check the keyboard/mouse engine is installed and the firewall allows DeskView.' }
} else { Write-Host 'Step 1/4: firewall rules and keyboard/mouse engine already in place.' }

# 2. Copy the program.
Write-Host "Step 2/4: installing to $installDir (from $Source)"
Stop-DeskView
New-Item -ItemType Directory -Force $installDir | Out-Null
foreach ($f in $files) {
    $dst = Join-Path $installDir $f
    if ($Source -match '^https?://') { Invoke-WebRequest ($Source.TrimEnd('/') + '/' + $f) -OutFile $dst -UseBasicParsing }
    elseif ((Resolve-Path $Source).Path -ne (Resolve-Path $installDir).Path) { Copy-Item (Join-Path $Source $f) $dst -Force }
}

# FFmpeg: use one on PATH if it can do what DeskView needs (screen capture, SRT, ffplay), else a private
# copy next to DeskView (no admin, no winget needed).
function Test-FFmpeg([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe) -or -not (Test-Path (Join-Path (Split-Path $exe) 'ffplay.exe'))) { return $false }
    $filters = & $exe -hide_banner -filters 2>$null | Out-String; $protocols = & $exe -hide_banner -protocols 2>$null | Out-String
    ($filters -match '\bddagrab\b') -and ($protocols -match '(?m)^\s*srt\s*$')
}
$ffDir = Join-Path $installDir 'ffmpeg'
$pathFF = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not (Test-FFmpeg $pathFF) -and -not (Test-FFmpeg (Join-Path $ffDir 'ffmpeg.exe'))) {
    Write-Host '        downloading FFmpeg (about 150 MB, once)...'
    $zip = Join-Path $env:TEMP 'deskview-ffmpeg.zip'
    Invoke-WebRequest 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip -UseBasicParsing
    $tmp = Join-Path $env:TEMP 'deskview-ffmpeg'; if (Test-Path $tmp) { [IO.Directory]::Delete($tmp, $true) }
    Expand-Archive $zip $tmp -Force
    New-Item -ItemType Directory -Force $ffDir | Out-Null
    Get-ChildItem $tmp -Recurse -Include ffmpeg.exe, ffplay.exe, ffprobe.exe | Copy-Item -Destination $ffDir -Force
    [IO.Directory]::Delete($tmp, $true); [IO.File]::Delete($zip)
    if (-not (Test-Path (Join-Path $ffDir 'ffplay.exe'))) { throw 'FFmpeg download failed.' }
}

# 3. Role and pairing.
Write-Host 'Step 3/4: pairing'
New-Item -ItemType Directory -Force $settingsDir | Out-Null
$settingsFile = Join-Path $settingsDir 'settings.json'
$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$ini = $engineIni
if ($Role) { $isServer = $Role -eq 'Server' }
else {
    $mode = if (Test-Path $ini) { [regex]::Match([IO.File]::ReadAllText($ini), '(?m)^coreMode=(\d)').Groups[1].Value } else { '' }
    if ($mode -eq '2') { $isServer = $true }
    elseif ($mode -eq '1') { $isServer = $false }
    else {
        # The engine is new here (no settings yet, or no role chosen), so it can't tell us the role.
        Write-Host '   This machine is not set up as server or client yet.' -ForegroundColor Yellow
        $isServer = (Read-Host '   Is this the machine whose keyboard and mouse you share (the SERVER)? [y/N]') -match '^[yY]'
        $Role = if ($isServer) { 'Server' } else { 'Client' }
        Write-Host "   Then set up the other machine the same way (as the other role)."
    }
}
if ($isServer) {
    if (-not $settings.PairCode) {
        $alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; $bytes = New-Object byte[] 12
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
        $settings | Add-Member PairCode (-join ($bytes | % { $alphabet[$_ % $alphabet.Length] })) -Force
    }
    Write-Host ''
    Write-Host "   This machine is the SERVER. Pairing code:  $($settings.PairCode)" -ForegroundColor Green
    Write-Host '   Enter it when installing on the other machine (it is also in the DeskView tray menu).'
} else {
    if (-not $PairCode -and $settings.PairCode) { $PairCode = $settings.PairCode }
    $codePattern = '^[2-9A-HJKMNP-Z]{8,12}$'
    while (-not $PairCode -or $PairCode.Trim().ToUpper() -notmatch $codePattern) {
        if ($PairCode) { Write-Host "   '$PairCode' is not a DeskView pairing code (8-12 letters/digits, as shown on the server)." -ForegroundColor Yellow }
        if (-not [Environment]::UserInteractive) { throw 'Pass the pairing code with -PairCode (no one to ask).' }
        $PairCode = Read-Host '   This machine is a CLIENT. Enter the pairing code shown on the server'
    }
    $settings | Add-Member PairCode ($PairCode.Trim().ToUpper()) -Force
}
if ($Role) { $settings | Add-Member Role $Role -Force }
$settings | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8

# 4. Start now and at every sign-in.
Write-Host 'Step 4/4: starting DeskView (tray icon) and adding it to startup'
$app = Join-Path $installDir 'DeskView.ps1'
$launchArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`""
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($startupLink); $sc.TargetPath = 'powershell.exe'; $sc.Arguments = $launchArgs; $sc.WindowStyle = 7; $sc.Description = 'DeskView'; $sc.Save()
Start-Process powershell -ArgumentList $launchArgs -WindowStyle Hidden
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
if ($isServer) { Write-Host '   Ctrl+Alt+1..9 shows the other machine on that monitor of yours (left to right), Ctrl+Alt+0 hides it.' }
else { Write-Host "   Ctrl+Alt+1..9 shows the server's monitor 1..9 here and lets you control it, Ctrl+Alt+0 comes back." }

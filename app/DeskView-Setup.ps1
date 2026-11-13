<#
  DeskView setup - the same command on both machines (Deskflow installed and connected first).

    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 [-Source <folder | https://.../app>] [-PairCode CODE]
    powershell -ExecutionPolicy Bypass -File DeskView-Setup.ps1 -Uninstall

  Install:
    - Administrator approval only if something is missing: two firewall rules (local network only:
      UDP 9000 video, TCP 9002 control) and FFmpeg / Deskflow via winget.
    - Copies DeskView to %LOCALAPPDATA%\DeskView, starts it, and starts it at every sign-in.
    - Pairing: the Deskflow server gets a code (shown here and in its tray menu); enter it on the client.
  Uninstall: stops DeskView, removes the startup entry, program folder, settings and firewall rules.
#>
param(
    [string]$Source,
    [string]$PairCode,
    [switch]$Uninstall,
    [switch]$Elevated,            # internal: the part that needs administrator rights
    [switch]$RemoveRules          # internal: elevated part of uninstall
)
$ErrorActionPreference = 'Stop'
$files = 'DeskView.ps1', 'DeskView-Portal.cs', 'DeskView-Input.cs', 'DeskView-Dxgi.cs', 'DeskView-Setup.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'DeskView'
$settingsDir = Join-Path $env:APPDATA 'DeskView'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskView.lnk'
$videoPort = 9000; $controlPort = 9002
$defaultSource = 'https://raw.githubusercontent.com/xl337x/DeskView/main/app'

# ---- elevated parts ------------------------------------------------------------------------------------
if ($RemoveRules) { Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; exit 0 }
if ($Elevated) {
    Write-Host 'Firewall: allowing DeskView video (UDP 9000) and control (TCP 9002) from the local network...'
    Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'DeskView video (UDP 9000)' -Direction Inbound -Protocol UDP -LocalPort $videoPort -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'DeskView control (TCP 9002)' -Direction Inbound -Protocol TCP -LocalPort $controlPort -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing FFmpeg...'
        winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements --silent | Out-Host
    }
    if (-not (Test-Path 'C:\Program Files\Deskflow\deskflow.exe')) {
        Write-Host 'Installing Deskflow...'
        winget install --id Deskflow.Deskflow -e --accept-source-agreements --accept-package-agreements --silent | Out-Host
    }
    exit 0
}

function Run-Elevated([string]$switchName) {
    $self = Join-Path $env:TEMP 'DeskView-Setup-elevated.ps1'
    Copy-Item $PSCommandPath $self -Force
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -$switchName"
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
    foreach ($dir in $installDir, $settingsDir) { if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) } }
    if (Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue) {
        Write-Host 'Removing the firewall rules (a Windows prompt will appear)...'
        [void](Run-Elevated 'RemoveRules')
    }
    Write-Host 'DeskView removed. Deskflow, FFmpeg and Deskflow''s screen layout file were left in place.' -ForegroundColor Green
    exit 0
}

# ---- install -------------------------------------------------------------------------------------------
Write-Host '== DeskView setup ==' -ForegroundColor Cyan
if (-not $Source) { $Source = if (Test-Path (Join-Path $PSScriptRoot 'DeskView.ps1')) { $PSScriptRoot } else { $defaultSource } }

# 1. Administrator part - only when something is actually missing.
$rules = @(Get-NetFirewallRule -DisplayName 'DeskView *' -ErrorAction SilentlyContinue).Count
$needAdmin = $rules -lt 2 -or -not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or -not (Test-Path 'C:\Program Files\Deskflow\deskflow.exe')
if ($needAdmin) {
    Write-Host 'Step 1/4: administrator approval for firewall rules / FFmpeg / Deskflow (a Windows prompt will appear)...'
    if (-not (Run-Elevated 'Elevated')) { Write-Warning 'The administrator part did not finish - the other machine may not reach this one.' }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
} else { Write-Host 'Step 1/4: firewall rules, FFmpeg and Deskflow already in place.' }

# 2. Copy the program.
Write-Host "Step 2/4: installing to $installDir (from $Source)"
Stop-DeskView
New-Item -ItemType Directory -Force $installDir | Out-Null
foreach ($f in $files) {
    $dst = Join-Path $installDir $f
    if ($Source -match '^https?://') { Invoke-WebRequest ($Source.TrimEnd('/') + '/' + $f) -OutFile $dst -UseBasicParsing }
    elseif ((Resolve-Path $Source).Path -ne (Resolve-Path $installDir).Path) { Copy-Item (Join-Path $Source $f) $dst -Force }
}

# 3. Role and pairing.
Write-Host 'Step 3/4: pairing'
New-Item -ItemType Directory -Force $settingsDir | Out-Null
$settingsFile = Join-Path $settingsDir 'settings.json'
$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$ini = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'
$isServer = [bool](Select-String -Path $ini -Pattern '^coreMode=2' -ErrorAction SilentlyContinue)
if ($isServer) {
    if (-not $settings.PairCode) {
        $code = -join ((1..8) | % { '23456789ABCDEFGHJKMNPQRSTUVWXYZ'[(Get-Random -Maximum 31)] })
        $settings | Add-Member PairCode $code -Force
    }
    Write-Host ''
    Write-Host "   This machine is the Deskflow SERVER. Pairing code:  $($settings.PairCode)" -ForegroundColor Green
    Write-Host '   Enter it when installing on the other machine (it is also in the DeskView tray menu).'
} else {
    if (-not $PairCode -and $settings.PairCode) { $PairCode = $settings.PairCode }
    if (-not $PairCode) { $PairCode = Read-Host '   This machine is a Deskflow CLIENT. Enter the pairing code shown on the server' }
    $settings | Add-Member PairCode ($PairCode.Trim().ToUpper()) -Force
}
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

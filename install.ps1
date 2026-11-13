# DeskView installer - downloads the latest DeskView from GitHub and runs its setup.
# Every line is a complete statement on purpose: "irm | iex" can feed this file to PowerShell line by line.
#
#   Install (each machine):            irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
#   With the pairing code (client):    $PairCode='ABCD2345'; irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
#   Add virtual screens (laptop): $DeskViewVirtualScreens=2; irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
#   Uninstall:                         $DeskViewUninstall=1; irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
if (-not $DeskViewRepo) { $DeskViewRepo = 'xl337x/DeskView' }
if (-not $DeskViewBranch) { $DeskViewBranch = 'main' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$dvBase = "https://raw.githubusercontent.com/$DeskViewRepo/$DeskViewBranch/app"
$dvSetup = Join-Path $env:TEMP 'DeskView-Setup.ps1'
Write-Host "Downloading DeskView setup from github.com/$DeskViewRepo ($DeskViewBranch)..."
Invoke-WebRequest "$dvBase/DeskView-Setup.ps1" -OutFile $dvSetup -UseBasicParsing -ErrorAction Stop
$dvArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dvSetup, '-Source', $dvBase)
if ($PairCode) { $dvArgs += @('-PairCode', $PairCode) }
if ($DeskViewUninstall) { $dvArgs += '-Uninstall' }
if ($null -ne $DeskViewVirtualScreens) { $dvArgs += @('-VirtualScreens', [string]$DeskViewVirtualScreens) }
& powershell @dvArgs

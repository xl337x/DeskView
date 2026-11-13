<#
  DeskView installer - downloads the latest DeskView from GitHub and runs its setup.

  Download it to a file and run it (antivirus products rightly distrust scripts piped straight into iex):
    iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\deskview-install.ps1
    powershell -ExecutionPolicy Bypass -File $env:TEMP\deskview-install.ps1 [-PairCode CODE] [-Role Server|Client] [-VirtualScreens N] [-Uninstall]
#>
param(
    [string]$PairCode,
    [ValidateSet('', 'Server', 'Client')] [string]$Role = '',
    [ValidateRange(-1, 4)] [int]$VirtualScreens = -1,
    [switch]$Uninstall,
    [string]$Repo = 'xl337x/DeskView',
    [string]$Branch = 'main'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$base = "https://raw.githubusercontent.com/$Repo/$Branch/app"
$setup = Join-Path $env:TEMP 'DeskView-Setup.ps1'
Write-Host "Downloading DeskView setup from github.com/$Repo ($Branch)..."
Invoke-WebRequest "$base/DeskView-Setup.ps1" -OutFile $setup -UseBasicParsing

$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup, '-Source', $base)
if ($PairCode) { $a += @('-PairCode', $PairCode) }
if ($Role) { $a += @('-Role', $Role) }
if ($VirtualScreens -ge 0) { $a += @('-VirtualScreens', [string]$VirtualScreens) }
if ($Uninstall) { $a += '-Uninstall' }
& powershell @a

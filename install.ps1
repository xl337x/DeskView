# DeskView installer - downloads the latest DeskView from GitHub and runs its setup.
# (Line comments on purpose: this file is run through "irm | iex", where a block comment can break.)
#
# Install (PowerShell, on each machine):
#     irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
#
# With the pairing code (on the Deskflow client), or to uninstall:
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -PairCode ABCD2345
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -Uninstall
param(
    [string]$PairCode,
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
if ($Uninstall) { $a += '-Uninstall' }
& powershell @a

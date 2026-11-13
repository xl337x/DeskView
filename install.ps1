<#
  DeskView installer - downloads DeskView from GitHub (one zip) and runs its setup.

  Download it to a file and run it (antivirus products rightly distrust scripts piped straight into iex):
    iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\deskview-install.ps1
    powershell -ExecutionPolicy Bypass -File $env:TEMP\deskview-install.ps1 [-PairCode CODE] [-Role Server|Client] [-ServerAddress IP] [-VirtualScreens N] [-Uninstall]

  -Ref picks a branch or tag (default: main). Developers can run app\DeskView-Setup.ps1 from a checkout instead.
#>
param(
    [string]$PairCode,
    [ValidateSet('', 'Server', 'Client')] [string]$Role = '',
    [string]$ServerAddress,
    [ValidateRange(-1, 4)] [int]$VirtualScreens = -1,
    [switch]$ClassicEngine,
    [switch]$Uninstall,
    [string]$Repo = 'xl337x/DeskView',
    [string]$Ref = 'main'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'    # Windows PowerShell's progress bar makes downloads many times slower
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'This PC only allows restricted PowerShell (constrained language mode), so DeskView cannot run here.' -ForegroundColor Yellow
    Write-Host 'Ask IT to allow DeskView (or to sign it).'; exit 1
}

# One download: the whole source tree of one branch or tag, so every file comes from the same version.
$work = Join-Path $env:TEMP ('deskview-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$zip = Join-Path $work 'deskview.zip'
Write-Host "Downloading DeskView from github.com/$Repo ($Ref)..."
$got = $false
foreach ($kind in 'heads', 'tags') {
    try { Invoke-WebRequest "https://codeload.github.com/$Repo/zip/refs/$kind/$Ref" -OutFile $zip -UseBasicParsing; $got = $true; break } catch { }
}
if (-not $got) { throw "Could not download $Repo ($Ref)." }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)
$app = Get-ChildItem $work -Directory | % { Join-Path $_.FullName 'app' } | ? { Test-Path (Join-Path $_ 'DeskView-Setup.ps1') } | Select -First 1
if (-not $app) { throw 'The download does not contain DeskView (app\DeskView-Setup.ps1 missing).' }

$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $app 'DeskView-Setup.ps1'), '-Source', $app)
if ($PairCode) { $a += @('-PairCode', $PairCode) }
if ($Role) { $a += @('-Role', $Role) }
if ($ServerAddress) { $a += @('-ServerAddress', $ServerAddress) }
if ($VirtualScreens -ge 0) { $a += @('-VirtualScreens', [string]$VirtualScreens) }
if ($ClassicEngine) { $a += '-ClassicEngine' }
if ($Uninstall) { $a += '-Uninstall' }
& powershell @a
$code = $LASTEXITCODE
try { [IO.Directory]::Delete($work, $true) } catch { }
exit $code

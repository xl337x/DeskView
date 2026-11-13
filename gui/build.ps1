<#
  Builds DeskView.exe (the DeskView app) with the C# compiler from Visual Studio Build Tools 2022.
    powershell -ExecutionPolicy Bypass -File gui\build.ps1            -> gui\bin\DeskView.exe
  Only the .NET Framework 4.8 that ships with Windows is needed to RUN it.
#>
param([string]$Out = (Join-Path $PSScriptRoot 'bin'))
$ErrorActionPreference = 'Stop'
$csc = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe"
if (-not (Test-Path $csc)) { throw "C# compiler not found: install Visual Studio 2022 Build Tools." }
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$app = Join-Path $PSScriptRoot '..\app'
$sources = @(Get-ChildItem (Join-Path $PSScriptRoot 'src') -Recurse -Filter *.cs | % FullName) +
           @('DeskView-Input.cs', 'DeskView-Dxgi.cs', 'DeskView-Portal.cs' | % { (Resolve-Path (Join-Path $app $_)).Path })
$refs = 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Web.Extensions.dll', 'Microsoft.CSharp.dll', 'System.Management.dll' | % { "/reference:$fw\$_" }
New-Item -ItemType Directory -Force $Out | Out-Null
$exe = Join-Path $Out 'DeskView.exe'
& $csc /nologo /noconfig /nostdlib+ "/reference:$fw\mscorlib.dll" @refs /target:winexe /langversion:latest /optimize+ /platform:x64 `
    /nowarn:1701,1702 "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')" "/win32icon:$(Join-Path $PSScriptRoot 'DeskView.ico')" "/out:$exe" @sources
if ($LASTEXITCODE -ne 0) { throw "Build failed." }
Copy-Item (Join-Path $PSScriptRoot 'app.config') "$exe.config" -Force
Write-Host "Built $exe" -ForegroundColor Green

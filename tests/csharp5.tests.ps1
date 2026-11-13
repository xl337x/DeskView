# DeskView runs from source: Windows PowerShell compiles app\**\*.cs at start with the C# compiler that ships with
# Windows (.NET Framework 4.x, C# 5). This gate compiles everything with that same compiler, so newer syntax
# ($"", =>, ?., out var, ...) fails here instead of on a user's PC.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
Check 'the in-box C# compiler is present' (Test-Path $csc) $csc

$app = Join-Path $PSScriptRoot '..\app'
$sources = @(Get-ChildItem $app -Recurse -Filter *.cs | % FullName)
$fw = Split-Path $csc
$refs = 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Web.Extensions.dll', 'Microsoft.CSharp.dll', 'System.Management.dll' | % { "/reference:$fw\$_" }
$out = Join-Path $env:TEMP "deskview-csharp5-$PID.dll"
$log = & $csc /nologo /target:library /langversion:5 /warn:0 "/out:$out" $refs $sources 2>&1
$errors = @($log | ? { $_ -match ': error CS' })
Check "all $($sources.Count) source files compile as C# 5 with the in-box compiler" ($errors.Count -eq 0 -and (Test-Path $out)) $(if ($errors) { "$($errors.Count) error(s), first: $($errors[0])" })
if ($errors) { $errors | Select -First 15 | % { "      $_" } }
if (Test-Path $out) { [IO.File]::Delete($out) }

"== csharp5: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

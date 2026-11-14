<#
  Runs the DeskView tests.
    tests\run-all.ps1          unit + loopback tests (mapping, input channel) - any Windows machine
    tests\run-all.ps1 -Live    also the live portal tests on every monitor (server with the client connected)
#>
param([switch]$Live)
$failed = 0
function Run($name, $file, $extra = @()) {
    Write-Host "`n### $name" -ForegroundColor Cyan
    & powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $file) @extra
    if ($LASTEXITCODE -ne 0) { $script:failed++ }
}
Run 'Height mapping between resolutions' 'mapping.tests.ps1'
Run 'Control channel (agent + forwarder, loopback)' 'input.tests.ps1'
Run 'Sending files (drag and drop)' 'files.tests.ps1'
Run 'Built-in switching and clipboard' 'link.tests.ps1'
Run 'C# 5 (compiles on every Windows PC)' 'csharp5.tests.ps1'
Run 'DeskView app logic' 'app.tests.ps1'
Run 'Install / update / uninstall (throwaway folders)' 'setup.tests.ps1'
Run 'Every control on every page, effect proven (report + screenshots)' 'gui-deep.tests.ps1'
if ($Live) { Run 'Portal on every monitor (live)' 'portal.tests.ps1' @('-All') }
Write-Host ''
if ($failed) { Write-Host "$failed test file(s) failed." -ForegroundColor Red; exit 1 } else { Write-Host 'All tests passed.' -ForegroundColor Green }

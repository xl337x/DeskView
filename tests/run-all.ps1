<#
  Runs the DeskView tests.
    tests\run-all.ps1          everything that leaves the mouse and keyboard alone (test windows briefly appear)
    tests\run-all.ps1 -WithInput  also the suites that drive the real mouse/keyboard: input channel replay, and every
                               control on every page with screenshots (gui-deep) - say so to whoever uses the PC
    tests\run-all.ps1 -Live    also the classic-engine portal on every monitor (server with the client connected)
  Live tests between the two real PCs are in tests\live (see its README).
#>
param([switch]$WithInput, [switch]$Live)
$failed = 0
function Run($name, $file, $extra = @()) {
    Write-Host "`n### $name" -ForegroundColor Cyan
    & powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $file) @extra
    if ($LASTEXITCODE -ne 0) { $script:failed++ }
}
Run 'C# 5 (compiles on every Windows PC)' 'csharp5.tests.ps1'
Run 'DeskView app logic (incl. smart screens, picture host)' 'app.tests.ps1'
Run 'Built-in switching, clipboard, protocol (loopback)' 'link.tests.ps1'
Run 'Sending files (loopback)' 'files.tests.ps1'
Run 'Height mapping between resolutions' 'mapping.tests.ps1'
Run 'Install / update / uninstall (throwaway folders)' 'setup.tests.ps1'
Run 'Every page, setup assistant, tray menu' 'gui.tests.ps1'
if ($WithInput) {
    Run 'Control channel with real input replay (moves the mouse)' 'input.tests.ps1'
    Run 'Every control on every page, effect proven (report + screenshots)' 'gui-deep.tests.ps1'
}
if ($Live) { Run 'Portal on every monitor (live)' 'portal.tests.ps1' @('-All') }
Write-Host ''
if ($failed) { Write-Host "$failed test file(s) failed." -ForegroundColor Red; exit 1 } else { Write-Host 'All tests passed.' -ForegroundColor Green }

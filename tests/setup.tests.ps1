# Install smoke test: runs the real setup into throwaway folders (no admin part, nothing started) and checks the
# result is a working DeskView: the app folder copied whole, FFmpeg usable, role and pairing code handed over,
# and the installed copy compiles and loads. Then uninstalls it again.
# Continue: setup's own (expected) error messages arrive on stderr and must not end this test
$ErrorActionPreference = 'Continue'
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }

$root = Join-Path $env:TEMP "deskview-setup-test-$PID"
$env:DESKVIEW_INSTALL = Join-Path $root 'install'; $env:DESKVIEW_HOME = Join-Path $root 'settings'
$setup = Join-Path $PSScriptRoot '..\app\DeskView-Setup.ps1'
try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode d4bbupsd -ServerAddress 192.168.1.37 -NoStart -SkipAdmin 2>&1 | Out-String
    Check 'setup finishes' ($LASTEXITCODE -eq 0) ($out -split "`n" | Select -Last 3 | Out-String).Trim()
    $srcFiles = @(Get-ChildItem (Join-Path $PSScriptRoot '..\app') -Recurse -File | % { $_.FullName.Substring((Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path.Length) })
    $missing = @($srcFiles | ? { -not (Test-Path (Join-Path $env:DESKVIEW_INSTALL $_)) })
    Check "the whole app folder is installed ($($srcFiles.Count) files)" ($missing.Count -eq 0) ($missing -join ', ')
    $ff = Join-Path $env:DESKVIEW_INSTALL 'ffmpeg\ffmpeg.exe'
    $onPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    Check 'FFmpeg available (a capable one on PATH, or the pinned build)' ((Test-Path $ff) -or $onPath) $(if (Test-Path $ff) { 'pinned build' } else { "PATH: $onPath" })
    $h = Get-Content (Join-Path $env:DESKVIEW_HOME 'setup.json') -Raw | ConvertFrom-Json
    Check 'role, pairing code (normalised) and server address handed to the app' ($h.Role -eq 'Client' -and $h.PairCode -eq 'D4BBUPSD' -and $h.ServerAddress -eq '192.168.1.37') ($h | ConvertTo-Json -Compress)
    $load = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$(Join-Path $env:DESKVIEW_INSTALL 'DeskView.ps1')' -LoadOnly; if ([DeskView.Program]) { 'loaded' }" 2>&1 | Out-String
    Check 'the installed copy compiles and loads with Windows'' own compiler' ($load -match 'loaded') $load.Trim()
    # reinstall over it: keeps FFmpeg, removes files that no longer exist in the app
    Set-Content (Join-Path $env:DESKVIEW_INSTALL 'stale-old-file.cs') '// old'
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode D4BBUPSD -NoStart -SkipAdmin 2>&1)
    Check 'updating removes old files (they would be compiled too) and keeps FFmpeg' (-not (Test-Path (Join-Path $env:DESKVIEW_INSTALL 'stale-old-file.cs')) -and ((Test-Path $ff) -or $onPath))
    $bad = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode 'NOPE' -NoStart -SkipAdmin 2>&1 | Out-String
    Check 'a wrong pairing code is refused when nobody can be asked' ($bad -match 'pairing code')
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall -SkipAdmin 2>&1)
    Check 'uninstall removes program and settings' (-not (Test-Path $env:DESKVIEW_INSTALL) -and -not (Test-Path $env:DESKVIEW_HOME))
}
finally {
    Remove-Item Env:\DESKVIEW_INSTALL, Env:\DESKVIEW_HOME -ErrorAction SilentlyContinue
    if (Test-Path $root) { [IO.Directory]::Delete($root, $true) }
}
"== setup: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

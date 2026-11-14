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
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode k7mpq3xr -ServerAddress 10.0.0.10 -NoStart -SkipAdmin 2>&1 | Out-String
    Check 'setup finishes' ($LASTEXITCODE -eq 0) ($out -split "`n" | Select -Last 3 | Out-String).Trim()
    $srcFiles = @(Get-ChildItem (Join-Path $PSScriptRoot '..\app') -Recurse -File | % { $_.FullName.Substring((Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path.Length) })
    $missing = @($srcFiles | ? { -not (Test-Path (Join-Path $env:DESKVIEW_INSTALL $_)) })
    Check "the whole app folder is installed ($($srcFiles.Count) files)" ($missing.Count -eq 0) ($missing -join ', ')
    $ff = Join-Path $env:DESKVIEW_INSTALL 'ffmpeg\ffmpeg.exe'
    $onPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    $stamp = Join-Path $env:DESKVIEW_INSTALL 'ffmpeg\deskview-pinned.txt'
    Check 'the pinned, checked FFmpeg is installed next to the app (never depends on one on PATH)' ((Test-Path $ff) -and (Test-Path $stamp)) $(if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { 'missing' })
    $before = (Get-ChildItem $env:DESKVIEW_INSTALL -Recurse -File | Measure-Object).Count
    $bad = Join-Path $root 'not-ffmpeg.zip'; Set-Content $bad 'nope'; [IO.File]::Delete($stamp)
    $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode k7mpq3xr -FFmpegZip $bad -NoStart -SkipAdmin 2>&1 | Out-String
    Check 'a wrong offline FFmpeg zip is refused and the install is left as it was' ($LASTEXITCODE -ne 0 -and $o2 -match 'checksum' -and (Test-Path $ff) -and (Get-ChildItem $env:DESKVIEW_INSTALL -Recurse -File | Measure-Object).Count -eq ($before - 1)) (($o2 -split "`n" | ? { $_ -match 'checksum' } | Select -First 1))
    Set-Content $stamp 'ffmpeg-n9.0.2-57-gd838f9f9ae-win64-gpl-shared-9.0.zip'
    $h = Get-Content (Join-Path $env:DESKVIEW_HOME 'setup.json') -Raw | ConvertFrom-Json
    Check 'role, pairing code (normalised) and server address handed to the app' ($h.Role -eq 'Client' -and $h.PairCode -eq 'K7MPQ3XR' -and $h.ServerAddress -eq $env:DV_SERVER_IP) ($h | ConvertTo-Json -Compress)
    $load = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$(Join-Path $env:DESKVIEW_INSTALL 'DeskView.ps1')' -LoadOnly; if ([DeskView.Program]) { 'loaded' }" 2>&1 | Out-String
    Check 'the installed copy compiles and loads with Windows'' own compiler' ($load -match 'loaded') $load.Trim()
    # reinstall over it: keeps FFmpeg, removes files that no longer exist in the app
    Set-Content (Join-Path $env:DESKVIEW_INSTALL 'stale-old-file.cs') '// old'
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode K7MPQ3XR -NoStart -SkipAdmin 2>&1)
    Check 'updating removes old files (they would be compiled too) and keeps FFmpeg' (-not (Test-Path (Join-Path $env:DESKVIEW_INSTALL 'stale-old-file.cs')) -and ((Test-Path $ff) -or $onPath))
    $bad = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup -Source (Join-Path $PSScriptRoot '..\app') -Role Client -PairCode 'NOPE' -NoStart -SkipAdmin 2>&1 | Out-String
    Check 'a wrong pairing code is refused when nobody can be asked' ($bad -match 'pairing code')
    $realBefore = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'AppData\\Local\\DeskView\\DeskView\.ps1' } | % ProcessId)
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $setup -Uninstall -SkipAdmin 2>&1)
    $realAfter = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'AppData\\Local\\DeskView\\DeskView\.ps1' } | % ProcessId)
    Check 'uninstalling a test install leaves the real running DeskView alone' (@($realBefore | ? { $realAfter -notcontains $_ }).Count -eq 0) "running before: $($realBefore.Count), after: $($realAfter.Count)"
    Check 'uninstall removes program and settings' (-not (Test-Path $env:DESKVIEW_INSTALL) -and -not (Test-Path $env:DESKVIEW_HOME))
}
finally {
    Remove-Item Env:\DESKVIEW_INSTALL, Env:\DESKVIEW_HOME -ErrorAction SilentlyContinue
    if (Test-Path $root) { [IO.Directory]::Delete($root, $true) }
}
"== setup: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

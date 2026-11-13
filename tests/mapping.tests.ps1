# Unit tests: how the portal maps cursor height between the local monitor and a remote screen of another
# resolution / shape (Fit mode adds black bars). No hardware or network needed.
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot '..\app\DeskView-Portal.cs') -ReferencedAssemblies System.Windows.Forms
$bf = [Reflection.BindingFlags]'NonPublic,Instance'
$toRemote = [DeskViewPortal].GetMethod('RemoteYFor', $bf)
$toLocal  = [DeskViewPortal].GetMethod('LocalYFor', $bf)
$script:pass = 0; $script:fail = 0

function Case($name, $mw, $mh, $rw, $rh, $pairs) {
    $p = New-Object DeskViewPortal; $p.PT = 0; $p.PB = $mh
    # Same picture placement as DeskView.ps1 Get-PictureRect ([double] matters: see the comment there).
    $s = [math]::Min([double]$mw / $rw, [double]$mh / $rh); $vh = [int][math]::Round($rh * $s)
    $p.VidH = $vh; $p.VidT = [int](($mh - $vh) / 2); $p.RemoteH = $rh
    foreach ($q in $pairs) {
        $got = $toRemote.Invoke($p, @([int]$q[0])); $back = $toLocal.Invoke($p, @([int]$got))
        $expectBack = [math]::Min([math]::Max($q[0], $p.VidT), $p.VidT + $vh - 1)   # bars clamp onto the picture
        $ok = ([math]::Abs($got - $q[1]) -le 2) -and ([math]::Abs($back - $expectBack) -le 2)
        if ($ok) { $script:pass++ } else { $script:fail++ }
        "{0}  {1,-34} local y={2,4} -> remote y={3,4} (want {4,4}) -> back {5,4}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $q[0], $got, $q[1], $back
    }
}

Case '1920x1080 on 1920x1080 (same)'     1920 1080 1920 1080 @(@(0, 0), @(540, 540), @(1079, 1079))
Case '1920x1200 (16:10) on 1080p'        1920 1080 1920 1200 @(@(0, 0), @(540, 600), @(1079, 1199))
Case '2560x1080 ultrawide on 1080p'      1920 1080 2560 1080 @(@(135, 0), @(539, 539), @(944, 1079), @(50, 0), @(1050, 1079))
Case '3840x2160 (4K) on 1080p'           1920 1080 3840 2160 @(@(0, 0), @(540, 1081), @(1079, 2159))
Case '1366x768 on 1080p'                 1920 1080 1366 768  @(@(0, 0), @(540, 384), @(1079, 767))
Case '1024x768 (4:3) on 3440x1440'       3440 1440 1024 768  @(@(0, 0), @(720, 384), @(1439, 767))

"== mapping: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

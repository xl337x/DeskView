# Loopback tests for sending files (drag and drop onto the other computer's picture): no mouse or keyboard needed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot '..\app\DeskView-Input.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }
function Same($a, $b) { (Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash }

$work = Join-Path $env:TEMP "deskview-files-test-$(Get-Random)"; $src = Join-Path $work 'src'; $dst = Join-Path $work 'received'
New-Item -ItemType Directory -Force "$src\folder\sub" | Out-Null
$rnd = New-Object byte[] (3 * 1024 * 1024 + 123); (New-Object Random 7).NextBytes($rnd); [IO.File]::WriteAllBytes("$src\big.bin", $rnd)
Set-Content "$src\hello.txt" 'hello from DeskView' -Encoding UTF8
Set-Content "$src\folder\a.txt" 'a'; Set-Content "$src\folder\sub\b.txt" 'b'
[IO.File]::WriteAllBytes("$src\empty.dat", [byte[]]@())

$agent = New-Object DeskViewAgent; $agent.Port = 9104; $agent.Code = 'TESTCODE2345'; $agent.ReceiveFolder = $dst; $agent.Start()
try {
    $err = [DeskViewFiles]::Send('127.0.0.1', 9104, 'TESTCODE2345', [string[]]@("$src\hello.txt", "$src\big.bin", "$src\empty.dat"), $null)
    Start-Sleep -Milliseconds 300
    Check 'files arrive (text, 3 MB binary, empty file)' ($err -eq $null -and (Same "$src\hello.txt" "$dst\hello.txt") -and (Same "$src\big.bin" "$dst\big.bin") -and (Test-Path "$dst\empty.dat") -and (Get-Item "$dst\empty.dat").Length -eq 0) "error=$err"
    $got = @(); $p = $null; while ($agent.Received.TryDequeue([ref]$p)) { $got += $p }
    Check 'the app is told which files arrived' ($got.Count -eq 3) "$($got.Count) reported"

    $err = [DeskViewFiles]::Send('127.0.0.1', 9104, 'TESTCODE2345', [string[]]@("$src\folder"), $null)
    Start-Sleep -Milliseconds 300
    Check 'a folder arrives with its structure' ($err -eq $null -and (Test-Path "$dst\folder\a.txt") -and (Test-Path "$dst\folder\sub\b.txt")) "error=$err"

    $err = [DeskViewFiles]::Send('127.0.0.1', 9104, 'TESTCODE2345', [string[]]@("$src\hello.txt"), $null)
    Start-Sleep -Milliseconds 300
    Check 'never overwrites: a second copy gets a new name' ((Test-Path "$dst\hello (2).txt") -and (Same "$src\hello.txt" "$dst\hello.txt"))

    $err = [DeskViewFiles]::Send('127.0.0.1', 9104, 'WRONGCODE999', [string[]]@("$src\hello.txt"), $null)
    Check 'a wrong pairing code is refused' ($err -ne $null) "error=$err"
    Start-Sleep -Milliseconds 300

    # hostile names, sent with the real protocol: must stay inside the receive folder
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9104); $s = $c.GetStream()
    $keys = [DvProto]::ClientHandshake($s, 'TESTCODE2345'); $seq = [uint64]0
    $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'FILES')
    foreach ($evil in '../../evil.txt', 'C:\Windows\evil2.txt', '..\..\..\evil3.txt', 'CON.txt') {
        $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'F ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($evil)) + ' 4')
        $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'D ' + [Convert]::ToBase64String([byte[]](1, 2, 3, 4)))
        $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'E')
    }
    $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'BYE'); Start-Sleep -Milliseconds 400; $c.Close()
    $escaped = (Test-Path (Join-Path $work 'evil.txt')) -or (Test-Path (Join-Path (Split-Path $work) 'evil.txt')) -or (Test-Path 'C:\Windows\evil2.txt')
    Check 'hostile names cannot escape the receive folder' ((-not $escaped) -and (Test-Path "$dst\evil.txt") -and (Test-Path "$dst\C_\Windows\evil2.txt") -and (Test-Path "$dst\evil3.txt") -and (Test-Path "$dst\_CON.txt"))

    # more data than announced: rejected, no half file left
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9104); $s = $c.GetStream()
    $keys = [DvProto]::ClientHandshake($s, 'TESTCODE2345'); $seq = [uint64]0
    $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'FILES')
    $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'F ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('liar.bin')) + ' 2')
    $seq++; [DvProto]::WriteFrame($s, $keys, $seq, 'D ' + [Convert]::ToBase64String([byte[]](1, 2, 3, 4, 5)))
    Start-Sleep -Milliseconds 400; $c.Close(); Start-Sleep -Milliseconds 200
    Check 'more data than announced: rejected, no half file left' (-not (Test-Path "$dst\liar.bin"))

    # a file session must not kick out the active remote-control session
    $ctl = New-Object Net.Sockets.TcpClient('127.0.0.1', 9104); $cs = $ctl.GetStream()
    $ck = [DvProto]::ClientHandshake($cs, 'TESTCODE2345'); [DvProto]::WriteFrame($cs, $ck, 1, 'P'); Start-Sleep -Milliseconds 300
    $before = $agent.Client
    [void][DeskViewFiles]::Send('127.0.0.1', 9104, 'TESTCODE2345', [string[]]@("$src\hello.txt"), $null); Start-Sleep -Milliseconds 300
    Check 'sending files does not interrupt remote control' ($before -ne '' -and $agent.Client -eq $before) "controller before='$before' after='$($agent.Client)'"
    $ctl.Close()

    $t = Measure-Command { [void][DeskViewFiles]::Send('127.0.0.1', 9104, 'TESTCODE2345', [string[]]@("$src\big.bin"), $null) }
    Check ('throughput: 3 MB in {0:N0} ms ({1:N0} MB/s on loopback)' -f $t.TotalMilliseconds, (3.0 / $t.TotalSeconds)) ($t.TotalSeconds -lt 10)
}
finally { $agent.Stop(); Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
"== files: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

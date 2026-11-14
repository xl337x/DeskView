# the laptop-side QA helper: runs an action in the signed-in desktop session (scheduled task) and prints its result.
#   laptop-dvqa.ps1 win X Y TEXT SECONDS   - a labelled test window at X,Y (physical px) for SECONDS
#   laptop-dvqa.ps1 rect                   - where the test window is now
#   laptop-dvqa.ps1 clipget / clipset TEXT - the clipboard
#   laptop-dvqa.ps1 view N                 - DeskView: show the server's screen N here (0 = back)
#   laptop-dvqa.ps1 files                  - files received in Downloads\DeskView
#   laptop-dvqa.ps1 dragfile X1 Y1 X2 Y2 F - drag file F from a test window at X1,Y1 to X2,Y2 with real mouse input (OLE)
param([string]$Action, [string]$A1, [string]$A2, [string]$A3, [string]$A4, [string]$A5)
# negative numbers are written m1620 (a leading '-' would be read as a parameter name)
foreach ($n in 'A1', 'A2', 'A3', 'A4') { $v = Get-Variable $n -ValueOnly; if ($v -match '^m\d+$') { Set-Variable $n ('-' + $v.Substring(1)) } }
$out = "C:\Users\Public\dvqa-$Action.txt"; $job = "C:\Users\Public\dvqa-$Action.ps1"; $task = "DeskViewQA-$Action"
if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }
$common = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Q {
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
}
"@
[void][Q]::SetThreadDpiAwarenessContext([IntPtr]-4)
'@
switch ($Action) {
    'win' {
        $body = @"
`$f = New-Object Windows.Forms.Form; `$f.Text = 'DeskView QA window'; `$f.StartPosition = 'Manual'; `$f.BackColor = [Drawing.Color]::FromArgb(37, 99, 235); `$f.TopMost = `$true
`$l = New-Object Windows.Forms.Label; `$l.Text = '$A3'; `$l.ForeColor = 'White'; `$l.Font = New-Object Drawing.Font('Segoe UI', 30); `$l.Dock = 'Fill'; `$l.TextAlign = 'MiddleCenter'; `$f.Controls.Add(`$l)
`$f.Show(); `$f.Location = New-Object Drawing.Point $A1, $A2; `$f.Size = New-Object Drawing.Size 900, 400
[Windows.Forms.Application]::DoEvents(); 'window at ' + `$f.Bounds | Set-Content '$out'
`$end = (Get-Date).AddSeconds($A4); while ((Get-Date) -lt `$end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
`$f.Close()
"@
    }
    'drag' {
        $body = @"
[void][Q]::SetCursorPos($A1, $A2); Start-Sleep -Milliseconds 300; [Q]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 300
'dragging' | Set-Content '$out'
for (`$i = 1; `$i -le 120; `$i++) { [void][Q]::SetCursorPos($A1 + ($A3 - $A1) * `$i / 120, $A2 + ($A4 - $A2) * `$i / 120); [Q]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60 }
Start-Sleep -Milliseconds 300; [Q]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
"@
    }
    'slide' {
        $body = @"
`$f = New-Object Windows.Forms.Form; `$f.Text = 'DeskView QA window'; `$f.StartPosition = 'Manual'; `$f.BackColor = [Drawing.Color]::FromArgb(22, 163, 74); `$f.TopMost = `$true
`$l = New-Object Windows.Forms.Label; `$l.Text = 'the laptop window moving across your monitors'; `$l.ForeColor = 'White'; `$l.Font = New-Object Drawing.Font('Segoe UI', 26); `$l.Dock = 'Fill'; `$l.TextAlign = 'MiddleCenter'; `$f.Controls.Add(`$l)
`$f.Show(); `$f.Size = New-Object Drawing.Size 900, 400
'sliding' | Set-Content '$out'
for (`$i = 0; `$i -le 100; `$i++) { `$f.Location = New-Object Drawing.Point ([int]($A1 + ($A3 - $A1) * `$i / 100)), $A2; [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
`$end = (Get-Date).AddSeconds(4); while ((Get-Date) -lt `$end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
`$f.Close()
"@
    }
    'rect' { $body = "`$h = [Q]::FindWindow(`$null, 'DeskView QA window'); `$r = New-Object Q+RECT; if (`$h -ne [IntPtr]::Zero -and [Q]::GetWindowRect(`$h, [ref]`$r)) { 'window at ' + `$r.L + ',' + `$r.T + ' .. ' + `$r.R + ',' + `$r.B | Set-Content '$out' } else { 'no window' | Set-Content '$out' }" }
    'clipget' { $body = "'clipboard: ' + [Windows.Forms.Clipboard]::GetText() | Set-Content '$out'" }
    'clipset' { $body = "[Windows.Forms.Clipboard]::SetDataObject('$A1', `$true, 10, 100); 'clipboard set' | Set-Content '$out'" }
    'view' { $body = "Set-Content (Join-Path `$env:APPDATA 'DeskView\command.txt') '$(if ($A1 -eq '0') { 'off' } else { $A1 })' -Encoding ASCII; 'view $A1 requested' | Set-Content '$out'" }
    'files' { $body = "Get-ChildItem (Join-Path `$env:USERPROFILE 'Downloads\DeskView') -ErrorAction SilentlyContinue | % { `$_.Name + ' ' + `$_.Length + ' bytes ' + `$_.LastWriteTime.ToString('HH:mm:ss') } | Set-Content '$out'; if (-not (Test-Path '$out')) { 'no files' | Set-Content '$out' }" }
    'dragfile' {
        $body = @"
`$f = New-Object Windows.Forms.Form; `$f.Text = 'DeskView QA drag source'; `$f.StartPosition = 'Manual'; `$f.TopMost = `$true; `$f.Location = New-Object Drawing.Point $A1, $A2; `$f.Size = New-Object Drawing.Size 300, 200
`$f.Show(); [Windows.Forms.Application]::DoEvents()
[void][Q]::SetCursorPos($A1 + 150, $A2 + 100); Start-Sleep -Milliseconds 300; [Q]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [Windows.Forms.Application]::DoEvents()
`$mover = [PowerShell]::Create(); [void]`$mover.AddScript({ param(`$x1, `$y1, `$x2, `$y2) Start-Sleep -Milliseconds 600; for (`$i = 1; `$i -le 30; `$i++) { [Q]::SetCursorPos(`$x1 + (`$x2 - `$x1) * `$i / 30, `$y1 + (`$y2 - `$y1) * `$i / 30); [Q]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }; Start-Sleep -Milliseconds 600; [Q]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero) }).AddArgument($A1 + 150).AddArgument($A2 + 100).AddArgument($A3).AddArgument($A4)
`$h = `$mover.BeginInvoke()
`$data = New-Object Windows.Forms.DataObject; `$list = New-Object Collections.Specialized.StringCollection; [void]`$list.Add('$A5'); `$data.SetFileDropList(`$list)
`$r = `$f.DoDragDrop(`$data, [Windows.Forms.DragDropEffects]::Copy)
'drop result: ' + `$r | Set-Content '$out'; `$f.Close()
"@
    }
}
Set-Content $job ($common + "`r`n" + $body)
schtasks /Create /TN $task /TR "powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $job" /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-Null
schtasks /Run /TN $task 2>&1 | Out-Null
$t0 = Get-Date; while (((Get-Date) - $t0).TotalSeconds -lt 40 -and -not (Test-Path $out)) { Start-Sleep -Milliseconds 300 }
Start-Sleep -Milliseconds 300
schtasks /Delete /TN $task /F 2>&1 | Out-Null
if (Test-Path $out) { Get-Content $out } else { 'no answer' }

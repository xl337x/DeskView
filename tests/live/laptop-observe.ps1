# the laptop side of the live input test: a text box on extra screen 2; records what is typed, where the pointer goes
# and the clipboard, with the laptop's clock, for the given seconds.
param([int]$Seconds = 25)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name D -Namespace X -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); public struct P { public int X, Y; } [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);'
[void][X.D]::SetProcessDpiAwarenessContext([IntPtr](-4))
$out = 'C:\Users\Public\dvqa-observe.txt'
$f = New-Object Windows.Forms.Form -Property @{ Text = 'DeskView QA input'; StartPosition = 'Manual'; TopMost = $true; BackColor = [Drawing.Color]::FromArgb(37, 99, 235) }
$f.Bounds = New-Object Drawing.Rectangle -5740, 150, 3780, 800
$tb = New-Object Windows.Forms.TextBox -Property @{ Multiline = $true; Dock = 'Fill'; Font = (New-Object Drawing.Font('Segoe UI', 28)) }
$f.Controls.Add($tb)
$log = New-Object Collections.Generic.List[string]
$f.Add_Shown({ $f.Activate() }); $tb.Add_KeyDown({ $log.Add("$(Get-Date -Format HH:mm:ss.fff) down $($_.KeyCode) mods=$($_.Modifiers) sel=$($tb.SelectionLength)") }); $tb.Add_KeyUp({ $log.Add("$(Get-Date -Format HH:mm:ss.fff) up   $($_.KeyCode) mods=$($_.Modifiers) sel=$($tb.SelectionLength)") })
$tb.Add_MouseDown({ $log.Add("$(Get-Date -Format HH:mm:ss.fff) click at $([Windows.Forms.Cursor]::Position)") })
$f.Show(); [Windows.Forms.Application]::DoEvents()
"ready $(Get-Date -Format HH:mm:ss.fff) form at $($f.Bounds)" | Set-Content $out
$lastClip = $null; $last = $null; $end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    [Windows.Forms.Application]::DoEvents()
    $p = New-Object X.D+P; [void][X.D]::GetCursorPos([ref]$p)
    if ($last -eq $null -or [math]::Abs($p.X - $last.X) + [math]::Abs($p.Y - $last.Y) -gt 40) { $log.Add("$(Get-Date -Format HH:mm:ss.fff) pointer $($p.X),$($p.Y)"); $last = $p }
    $c = try { [Windows.Forms.Clipboard]::GetText() } catch { '?' }; if ($c -ne $lastClip) { $log.Add("$(Get-Date -Format HH:mm:ss.fff) clipboard now [$c]"); $lastClip = $c }
    Start-Sleep -Milliseconds 15
}
$clip = try { [Windows.Forms.Clipboard]::GetText() } catch { "(clipboard error $_)" }
$log.Add("text typed: [$($tb.Text)]"); $log.Add("clipboard: [$clip]")
$f.Close()
$log | Add-Content $out
'RUN DONE' | Add-Content $out

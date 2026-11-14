# the server side of the laptop-controls-the server test: a window on the main monitor that switches colour on every key press
# (what the laptop measures through the picture), with a text box; logs clicks, keys and the clipboard.
param([int]$Seconds = 60, [string]$Out = "$env:TEMP\dvqa-server-observe.txt")
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name D -Namespace X -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);'
[void][X.D]::SetProcessDpiAwarenessContext([IntPtr](-4))
$p = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$f = New-Object Windows.Forms.Form -Property @{ Text = 'DeskView QA (from the laptop)'; StartPosition = 'Manual'; TopMost = $true; BackColor = [Drawing.Color]::FromArgb(37, 99, 235); KeyPreview = $true }
$f.Bounds = New-Object Drawing.Rectangle ($p.X + 260), ($p.Y + 140), ($p.Width - 520), ($p.Height - 280)
$tb = New-Object Windows.Forms.TextBox -Property @{ Dock = 'Top'; Font = (New-Object Drawing.Font('Segoe UI', 24)) }
$f.Controls.Add($tb)
$log = New-Object Collections.Generic.List[string]
$f.Add_KeyDown({ $log.Add("$(Get-Date -Format HH:mm:ss.fff) down $($_.KeyCode) mods=$($_.Modifiers)"); if ($_.KeyCode -eq 'F9') { $f.BackColor = if ($f.BackColor.G -lt 120) { [Drawing.Color]::FromArgb(22, 163, 74) } else { [Drawing.Color]::FromArgb(37, 99, 235) }; $f.Refresh() } })
$tb.Add_MouseDown({ $log.Add("$(Get-Date -Format HH:mm:ss.fff) click at $([Windows.Forms.Cursor]::Position)") })
$f.Show(); $f.Activate(); [Windows.Forms.Application]::DoEvents()
"ready $(Get-Date -Format HH:mm:ss.fff) form at $($f.Bounds)" | Set-Content $Out
$lastClip = $null; $end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    [Windows.Forms.Application]::DoEvents()
    $c = try { [Windows.Forms.Clipboard]::GetText() } catch { '?' }; if ($c -ne $lastClip) { $log.Add("$(Get-Date -Format HH:mm:ss.fff) clipboard now [$c]"); $lastClip = $c }
    Start-Sleep -Milliseconds 10
}
$log.Add("text typed: [$($tb.Text)]")
$f.Close(); $log | Add-Content $Out; 'RUN DONE' | Add-Content $Out

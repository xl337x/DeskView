<#
  Drives the DeskView app's real windows: every page, button, checkbox, list and number box; the setup assistant;
  the tray menu. Runs the app's code in this process in test mode (own settings folder, no engine service calls,
  no video), so the real setup is never touched. Screenshots go to $env:TEMP\deskview-gui-qa.
    powershell -STA -File tests\gui.tests.ps1
#>
$ErrorActionPreference = 'Stop'
$home2 = Join-Path $env:TEMP "deskview-gui-qa-home"; $shots = Join-Path $env:TEMP 'deskview-gui-qa'
foreach ($d in $home2, $shots) { if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d | Out-Null }
$env:DESKVIEW_HOME = $home2; $env:DESKVIEW_DRYRUN = '1'; $env:DESKVIEW_NOMEDIA = '1'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
$asm = [Reflection.Assembly]::LoadFile((Resolve-Path (Join-Path $PSScriptRoot '..\gui\bin\DeskView.exe')).Path)
function T($n) { $asm.GetType($n, $true) }
$bf = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$script:pass = 0; $script:fail = 0; $script:dialogs = New-Object System.Collections.ArrayList
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++ } else { $script:fail++ }; "{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail }
function Pump($ms = 150) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }

# Answers message boxes (Yes / OK) shown by our own process and records their text.
Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public static class DialogAnswerer {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static readonly List<string> Seen = new List<string>();
  static Thread t; static volatile bool stop;
  public static void Start() { stop = false; t = new Thread(Loop) { IsBackground = true }; t.Start(); }
  public static void Stop() { stop = true; }
  static void Loop() {
    uint me = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    while (!stop) {
      EnumWindows((h, l) => {
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pid != me || !IsWindowVisible(h)) return true;
        var c = new StringBuilder(64); GetClassName(h, c, 64);
        if (c.ToString() != "#32770") return true;
        var text = new StringBuilder();
        EnumChildWindows(h, (ch, l2) => { var cc = new StringBuilder(64); GetClassName(ch, cc, 64); if (cc.ToString() == "Static") { var s = new StringBuilder(512); GetWindowText(ch, s, 512); if (s.Length > 0) text.Append(s).Append(' '); } return true; }, IntPtr.Zero);
        lock (Seen) Seen.Add(text.ToString().Trim());
        PostMessage(h, 0x0111, (IntPtr)6, IntPtr.Zero);   // IDYES
        PostMessage(h, 0x0111, (IntPtr)1, IntPtr.Zero);   // IDOK
        return true; }, IntPtr.Zero);
      Thread.Sleep(100);
    }
  }
}
'@
[DialogAnswerer]::Start()
# the clipboard can be held for a moment by other programs (the engine syncs it): retry reads
# a locked screen denies every program the clipboard: skip those checks then (they pass on an unlocked desktop)
$script:clipOk = $true; try { [Windows.Forms.Clipboard]::SetText('probe') } catch { $script:clipOk = $false; 'SKIP  clipboard checks: the clipboard is not available (screen locked?)' }
function Clip { for ($i = 0; $i -lt 20; $i++) { try { return (Clip) } catch { Start-Sleep -Milliseconds 100 } }; '' }
function All-Controls($c) { foreach ($x in $c.Controls) { $x; All-Controls $x } }
function Shot($form, $name) { $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height; $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height)); $bmp.Save((Join-Path $shots "$name.png")); $bmp.Dispose() }
function Settings { (New-Object Web.Script.Serialization.JavaScriptSerializer).DeserializeObject([IO.File]::ReadAllText((Join-Path $home2 'app.json'))) }

# ------------------------------------------------------------------------------------------------- setup assistant
$SettingsType = T 'DeskView.AppSettings'; $EngineType = T 'DeskView.Engine'
$s = [Activator]::CreateInstance($SettingsType); $s.VideoPort = 9100; $s.ControlPort = 9102; $s.ComputerName = 'QA-DESK'
$engine = [Activator]::CreateInstance($EngineType, @($s))
$wiz = [Activator]::CreateInstance((T 'DeskView.UI.SetupWizard'), @($engine))
$wiz.Show(); Pump 300
$next = All-Controls $wiz | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Next' } | Select -First 1
$back = All-Controls $wiz | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Back' } | Select -First 1
Shot $wiz 'wizard-1-welcome'
Check 'assistant: Back is disabled on the first step' (-not $back.Enabled)
$next.PerformClick(); Pump 300; Shot $wiz 'wizard-2-role'
$before = $script:dialogs.Count; [DialogAnswerer]::Seen.Clear()
$next.PerformClick(); Pump 600
Check 'assistant: refuses to continue without a role (and says why)' (([DialogAnswerer]::Seen -join ' ') -match 'Server or Client') (([DialogAnswerer]::Seen -join ' '))
$radio = All-Controls $wiz | ? { $_ -is [Windows.Forms.RadioButton] -and $_.Text -like 'Server*' } | Select -First 1
$radio.Checked = $true; $next.PerformClick(); Pump 300; Shot $wiz 'wizard-3-names'
Check 'assistant: server step shows this computer''s addresses' ((All-Controls $wiz | ? { $_ -is [Windows.Forms.Label] -and $_.Text -match '\d+\.\d+\.\d+\.\d+' }).Count -gt 0)
$next.PerformClick(); Pump 300; Shot $wiz 'wizard-4-pairing'
$codeLabel = All-Controls $wiz | ? { $_ -is [Windows.Forms.Label] -and $_.Text -match '^[2-9A-HJKMNP-Z]{12}$' } | Select -First 1
Check 'assistant: shows a 12-character pairing code' ($codeLabel -ne $null) $codeLabel.Text
$copy = All-Controls $wiz | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Copy' } | Select -First 1
if ($script:clipOk) {
    $copy.PerformClick(); Pump 200
    Check 'assistant: Copy puts the code on the clipboard' ((Clip) -eq $codeLabel.Text)
}
$next.PerformClick(); Pump 300; Shot $wiz 'wizard-5-screens'
$combo = All-Controls $wiz | ? { $_ -is [Windows.Forms.ComboBox] -and $_.Items.Count -gt 2 } | Select -First 1
$combo.SelectedIndex = 1
$next.PerformClick(); Pump 600; Shot $wiz 'wizard-6-ready'
Check 'assistant: last step offers Finish' ($next.Text -eq 'Finish')
$back.PerformClick(); Pump 200; Check 'assistant: Back goes to the previous step' ($next.Text -eq 'Next'); $next.PerformClick(); Pump 300
$next.PerformClick(); Pump 800
$st = Settings
Check 'assistant: Finish saves role, code and the chosen monitor' ($st.Role -eq 1 -and $st.SetupDone -and $st.PairCode -eq $codeLabel.Text -and $st.Screens.Count -eq 1) "role=$($st.Role) screens=$($st.Screens.Keys -join ',')"
Check 'assistant: Finish starts the engine (dry run: "start" sent)' ([DeskView.CoreControl]::Sent -contains 'start')
Check 'assistant: engine settings written' (Test-Path (Join-Path $home2 'engine.conf'))

# ------------------------------------------------------------------------------------------------- tray app + window
$s = $SettingsType::Load(); $s.RemoteName = 'leet'; $s.Save()
$engine = [Activator]::CreateInstance($EngineType, @($s))
$tray = [Activator]::CreateInstance((T 'DeskView.TrayApp'), @($engine, $true)); Pump 800
$form = (T 'DeskView.TrayApp').GetField('window', $bf).GetValue($tray)
Check 'window opens' ($form -ne $null -and $form.Visible)
$form.Size = New-Object Drawing.Size 1000, 760; Pump 300

$pages = 'Overview', 'What you can do', 'Screens', 'Connection', 'Switching & input', 'Security', 'Logs', 'About'
$skip = @('Open log folder')   # opens Explorer
# locked screen: no clipboard, and modal windows can't be answered there
if (-not $script:clipOk) { $skip += 'Copy', 'Copy command', 'Setup assistant...' }
foreach ($p in $pages) {
    $form.ShowPage($p); Pump 500; Shot $form ("page-" + ($p -replace '[^\w]', ''))
    $ctrls = @(All-Controls $form)
    # text that does not fit: labels clipped by their width
    $clipped = @($ctrls | ? { $_ -is [Windows.Forms.Label] -and $_.AutoSize -and $_.MaximumSize.Width -gt 0 -and $_.PreferredSize.Width -gt $_.MaximumSize.Width + 2 })
    Check "page '$p': opens without errors ($($ctrls.Count) controls)" ($ctrls.Count -gt 3)
    $errors = @()
    foreach ($c in $ctrls) {
        try {
            if ($c -is [Windows.Forms.Button] -and $c.Visible -and $c.Enabled -and $c.Text -notin $skip) { [DialogAnswerer]::Seen.Clear(); $c.PerformClick(); Pump 250 }
            elseif ($c -is [Windows.Forms.CheckBox]) { $v = $c.Checked; $c.Checked = -not $v; $c.Checked = $v }
            elseif ($c -is [Windows.Forms.ComboBox] -and $c.Items.Count -gt 0) { $i = $c.SelectedIndex; for ($k = 0; $k -lt $c.Items.Count; $k++) { $c.SelectedIndex = $k }; $c.SelectedIndex = [Math]::Max(0, $i) }
            elseif ($c -is [Windows.Forms.NumericUpDown]) { $v = $c.Value; $c.Value = $c.Maximum; $c.Value = $c.Minimum; $c.Value = $v }
        } catch { $errors += "$($c.GetType().Name) '$($c.Text)': $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }
    Check "page '$p': every button / box / list works without errors" ($errors.Count -eq 0) ($errors -join ' | ')
    # the page may have been rebuilt by a button (e.g. Save): go back to it for the next one
}

# specific effects
$form.ShowPage('Overview'); Pump 300; [DeskView.CoreControl]::Sent.Clear()
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Stop' }).PerformClick(); Pump 200
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Start / restart' }).PerformClick(); Pump 900
Check 'Overview: Stop and Start/restart send stop + start to the engine' (([DeskView.CoreControl]::Sent -contains 'stop') -and ([DeskView.CoreControl]::Sent -contains 'start')) (([DeskView.CoreControl]::Sent) -join ',')

$form.ShowPage('Switching & input'); Pump 300
$cb = All-Controls $form | ? { $_ -is [Windows.Forms.CheckBox] -and $_.Text -eq 'Share the clipboard' } | Select -First 1
$cb.Checked = $false
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Save and apply' } | Select -First 1).PerformClick(); Pump 400
Check 'Switching & input: Save writes the setting and the engine config' (-not (Settings).ClipboardEnabled -and ([IO.File]::ReadAllText((Join-Path $home2 'engine.conf')) -match '(?m)^enableClipboard=false'))
$form.ShowPage('Switching & input'); Pump 300
(All-Controls $form | ? { $_ -is [Windows.Forms.CheckBox] -and $_.Text -eq 'Share the clipboard' } | Select -First 1).Checked = $true
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Save and apply' } | Select -First 1).PerformClick(); Pump 400

$form.ShowPage('Connection'); Pump 300
$code = All-Controls $form | ? { $_ -is [Windows.Forms.TextBox] -and $_.Font.Name -eq 'Consolas' } | Select -First 1
$old = (Settings).PairCode
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'New code' }).PerformClick(); Pump 600
Check 'Connection: New code asks first, then makes a new valid code' ($code.Text -ne $old -and $code.Text -match '^[2-9A-HJKMNP-Z]{12}$' -and (([DialogAnswerer]::Seen -join ' ') -match 'new code')) $code.Text
$side = All-Controls $form | ? { $_ -is [Windows.Forms.ComboBox] -and $_.Items -contains 'Bottom' } | Select -First 1
$side.SelectedItem = 'Bottom'
(All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Save and apply' } | Select -First 1).PerformClick(); Pump 600
Check 'Connection: Save stores the new code and the layout (other computer below)' ((Settings).PairCode -eq $code.Text -and ([IO.File]::ReadAllText((Join-Path $home2 'layout.conf')) -match 'down = leet'))

$form.ShowPage('Screens'); Pump 300
$engine.SetScreen(($engine.S.Screens.Keys | Select -First 1), 0); Pump 300
Check 'Screens: a monitor can be given back to its own desktop' ($engine.S.Screens.Count -eq 0)
$first = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X } | Select -First 1
$engine.SetScreen(($first.DeviceName -replace '^\\\\\.\\', ''), 2); Pump 300
Check 'Screens: a monitor can show the other computer''s screen 2' ($engine.S.Screens[($first.DeviceName -replace '^\\\\\.\\', '')] -eq 2)
$cmd = All-Controls $form | ? { $_ -is [Windows.Forms.TextBox] -and $_.Text -like '*VirtualScreens*' } | Select -First 1
if ($script:clipOk) {
    (All-Controls $form | ? { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Copy command' }).PerformClick(); Pump 200
    Check 'Screens: Copy command copies the virtual-screens command' ((Clip) -eq $cmd.Text)
}

$form.ShowPage('Logs'); Pump 600
$box = All-Controls $form | ? { $_ -is [Windows.Forms.TextBox] -and $_.Multiline } | Select -First 1
Check 'Logs: shows the engine log and DeskView''s own log' ($box.Text -match '=== engine ===' -and $box.Text -match '=== DeskView ===')

# tray menu
$ni = (T 'DeskView.TrayApp').GetField('tray', $bf).GetValue($tray)
$ni.ContextMenuStrip.Show(0, 0); Pump 300
$items = @($ni.ContextMenuStrip.Items | ? { $_ -is [Windows.Forms.ToolStripMenuItem] })
Check "tray menu: $($items.Count) entries ($(($items | % Text) -join ' | '))" ($items.Count -ge 4)
$terr = @()
foreach ($it in $items) {
    if ($it.Text -eq 'Exit') { continue }
    try { if ($it.DropDownItems.Count) { foreach ($sub in @($it.DropDownItems | ? { $_ -is [Windows.Forms.ToolStripMenuItem] })) { $sub.PerformClick(); Pump 200 } } else { $it.PerformClick(); Pump 300 } }
    catch { $terr += "$($it.Text): $($_.Exception.Message)" }
}
$ni.ContextMenuStrip.Close()
Check 'tray menu: every entry and sub-entry works' ($terr.Count -eq 0) ($terr -join ' | ')

# Exit
$exit = $ni.ContextMenuStrip.Items | ? { $_.Text -eq 'Exit' }
$exit.PerformClick(); Pump 500
Check 'tray menu: Exit removes the tray icon and the portal' (-not $ni.Visible -and -not ([IO.File]::ReadAllText((Join-Path $home2 'engine.conf')) -match 'portal='))

[DialogAnswerer]::Stop()
"dialogs seen: " + ([DialogAnswerer]::Seen.Count)
"screenshots: $shots"
"== gui: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

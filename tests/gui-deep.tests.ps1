# Deep GUI test: every button, checkbox, list, number and text field on every page is used like a user would, and its
# EFFECT is proven - the value saved in app.json, the line written to the engine settings, the command sent to the engine,
# the clipboard content, the window that opened. Before/after screenshots of every step and an HTML report with all the
# proof go to $env:TEMP\deskview-deep-qa. Runs on a throwaway settings folder with the engine in dry-run mode (commands
# are recorded, never sent) and without video, so the real setup is never touched.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
$work = Join-Path $env:TEMP "deskview-deep-$PID"; $home2 = Join-Path $work 'home'
New-Item -ItemType Directory -Force $home2 | Out-Null
$env:DESKVIEW_HOME = $home2; $env:DESKVIEW_DRYRUN = '1'; $env:DESKVIEW_NOMEDIA = '1'
$shots = Join-Path $env:TEMP 'deskview-deep-qa'
if (Test-Path $shots) { [IO.Directory]::Delete($shots, $true) }; New-Item -ItemType Directory $shots | Out-Null

& (Join-Path $PSScriptRoot '..\app\DeskView.ps1') -LoadOnly   # exactly what users run
$asm = [DeskView.Program].Assembly
function T($n) { $asm.GetType($n, $true) }
$bf = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$Core = T 'DeskView.CoreControl'

# ------------------------------------------------------------------------------------------------- helpers
Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public static class DeepAnswerer {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static readonly List<string> Seen = new List<string>();
  static volatile bool stop;
  public static void Start() { stop = false; new Thread(Loop) { IsBackground = true }.Start(); }
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
        PostMessage(h, 0x0111, (IntPtr)6, IntPtr.Zero); PostMessage(h, 0x0111, (IntPtr)1, IntPtr.Zero);
        return true; }, IntPtr.Zero);
      Thread.Sleep(100);
    }
  }
}
'@
[DeepAnswerer]::Start()
function Pump($ms = 200) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }
function Walk($c, $card) {
    foreach ($x in $c.Controls) {
        $t = $card
        if ($x -is [Windows.Forms.Panel] -and $x.Controls.Count -gt 0 -and $x.Controls[0] -is [Windows.Forms.Label] -and $x.Controls[0].Font.Size -ge 11) { $t = $x.Controls[0].Text }
        [pscustomobject]@{ C = $x; Card = $t }; Walk $x $t
    }
}
function Find($card, $type, $text = $null, $index = 0) {
    $all = @(Walk $script:form '' | ? { $_.Card -eq $card -and $_.C -is $type -and $_.C.Visible -and ($text -eq $null -or $_.C.Text -eq $text) } | % C)
    if ($all.Count -le $index) { throw "control not found: [$card] $($type.Name) '$text' #$index" }
    $all[$index]
}
function J { (New-Object Web.Script.Serialization.JavaScriptSerializer).DeserializeObject([IO.File]::ReadAllText((Join-Path $home2 'app.json'))) }
function Ini { if (Test-Path $Core::ConfigPath) { [IO.File]::ReadAllText($Core::ConfigPath) } else { '' } }
function IniVal($key) { $m = [regex]::Match((Ini), "(?m)^$([regex]::Escape($key))=(.*?)\s*$"); if ($m.Success) { $m.Groups[1].Value } else { '<missing>' } }
function Sent { @($Core::Sent) -join ',' }
function ClearSent { $Core::Sent.Clear() }
function B($v) { if ($v) { 'true' } else { 'false' } }
$script:n = 0
function Shot($tag) {
    $script:n++; $name = '{0:000}-{1}.png' -f $script:n, ($tag -replace '[^\w]+', '-')
    $f = $script:form; $bmp = New-Object Drawing.Bitmap $f.Width, $f.Height
    $f.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $f.Width, $f.Height)); $bmp.Save((Join-Path $shots $name)); $bmp.Dispose(); $name
}
function Click-Args($pt) { $a = New-Object 'object[]' 1; $a[0] = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, $pt.X, $pt.Y, 0); ,$a }
function Clip { for ($i = 0; $i -lt 20; $i++) { try { return [Windows.Forms.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 100 } }; '' }
$script:clipOk = $true; try { [Windows.Forms.Clipboard]::SetText('probe') } catch { $script:clipOk = $false }
$script:report = New-Object Collections.ArrayList; $script:pass = 0; $script:fail = 0
function Proof($page, $control, $did, $expected, $actual, [bool]$ok, $before, $after) {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    [void]$script:report.Add([pscustomobject]@{ Role = $script:role; Page = $page; Control = $control; Did = $did; Expected = $expected; Actual = $actual; Ok = $ok; Before = $before; After = $after })
    "{0}  [{1}] {2} > {3}: {4}  => {5}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $script:role, $page, $control, $did, $actual
}
function Open($page) { $script:form.ShowPage($page); Pump 250; $script:page = $page }
function SaveOn($card) { (Find $card ([Windows.Forms.Button]) 'Save and apply').PerformClick(); Pump 300 }

# A checkbox: flip it, save, prove app.json (and the engine setting, if it has one) now hold the new value.
function TestCheck($card, $text, $idx, $prop, $iniKey, $saveCard) {
    Open $script:page
    $c = Find $card ([Windows.Forms.CheckBox]) $text $idx; $old = $c.Checked; $new = -not $old
    $before = Shot "$script:page $text before"; ClearSent
    $c.Checked = $new; Pump 100; if ($saveCard) { SaveOn $saveCard }
    $after = Shot "$script:page $text after"
    $j = J; $saved = $j[$prop]; $iv = if ($iniKey) { IniVal $iniKey } else { $null }
    $ok = ($saved -eq $new) -and (-not $iniKey -or $iv -eq (B $new))
    Proof $script:page "checkbox '$text'" "$(B $old) -> $(B $new)" "app.json $prop=$(B $new)$(if ($iniKey) { "; engine $iniKey=$(B $new)" })" "app.json $prop=$(B $saved)$(if ($iniKey) { "; engine $iniKey=$iv" })" $ok $before $after
}
# A number box: set a new value, save, prove both places.
function TestNumber($card, $idx, $value, $prop, $expectProp, $iniKey, $expectIni, $saveCard, $label) {
    Open $script:page
    $c = Find $card ([Windows.Forms.NumericUpDown]) $null $idx; $old = $c.Value
    $before = Shot "$script:page $label before"
    $c.Value = $value; Pump 100; if ($saveCard) { SaveOn $saveCard }
    $after = Shot "$script:page $label after"
    $j = J; $saved = "$($j[$prop])"; $iv = if ($iniKey) { IniVal $iniKey } else { $null }
    $ok = ($saved -eq "$expectProp") -and (-not $iniKey -or $iv -eq "$expectIni")
    Proof $script:page "number '$label'" "$old -> $value" "app.json $prop=$expectProp$(if ($iniKey) { "; engine $iniKey=$expectIni" })" "app.json $prop=$saved$(if ($iniKey) { "; engine $iniKey=$iv" })" $ok $before $after
}
# A list: pick an entry, save, prove both places.
function TestCombo($card, $idx, $pick, $prop, $expectProp, $iniKey, $expectIni, $saveCard, $label) {
    Open $script:page
    $c = Find $card ([Windows.Forms.ComboBox]) $null $idx; $old = "$($c.SelectedItem)"
    $before = Shot "$script:page $label before"; ClearSent
    $c.SelectedItem = $pick; Pump 150; if ($saveCard) { SaveOn $saveCard }
    $after = Shot "$script:page $label after"
    $j = J; $saved = "$($j[$prop])"; $iv = if ($iniKey) { IniVal $iniKey } else { $null }
    $ok = ($saved -eq "$expectProp") -and (-not $iniKey -or $iv -eq "$expectIni")
    Proof $script:page "list '$label'" "'$old' -> '$pick'" "app.json $prop=$expectProp$(if ($iniKey) { "; engine $iniKey=$expectIni" })" "app.json $prop=$saved$(if ($iniKey) { "; engine $iniKey=$iv" })" $ok $before $after
}

# ------------------------------------------------------------------------------------------------- per role
$SettingsType = T 'DeskView.AppSettings'
foreach ($script:role in 'Server', 'Client') {
    $st = [Activator]::CreateInstance($SettingsType)
    $st.Role = [Enum]::Parse((T 'DeskView.Role'), $script:role); $st.ComputerName = 'QA-DESK'; $st.RemoteName = 'leet'; $st.PairCode = 'D4BBUPSD'
    $st.SetupDone = $true; $st.InputEngine = 'Classic'; $st.ServerAddress = '192.168.1.37'; $st.VideoPort = 9100; $st.ControlPort = 9102; $st.Save()
    $engine = [Activator]::CreateInstance((T 'DeskView.Engine'), @($st))
    $script:form = [Activator]::CreateInstance((T 'DeskView.UI.MainForm'), @($engine)); $script:form.Size = New-Object Drawing.Size 1000, 760
    $script:form.Show(); Pump 400

    # ---- Overview
    Open 'Overview'
    $b = Shot 'Overview start before'; ClearSent; (Find 'Engine' ([Windows.Forms.Button]) 'Start / restart').PerformClick(); Pump 300; $a = Shot 'Overview start after'
    Proof 'Overview' "button 'Start / restart'" 'click' 'engine gets stop, then its settings file (this app''s engine.conf), then start' (Sent) ((Sent) -match '^stop,configFile=.*engine\.conf,.*start$') $b $a
    $b = Shot 'Overview stop before'; ClearSent; (Find 'Engine' ([Windows.Forms.Button]) 'Stop').PerformClick(); Pump 300; $a = Shot 'Overview stop after'
    Proof 'Overview' "button 'Stop'" 'click' 'engine gets stop' (Sent) ((Sent) -eq 'stop') $b $a
    # the assistant is a dialog: a timer looks for it, photographs it and closes it
    $script:wizSeen = $null
    $tm = New-Object Windows.Forms.Timer; $tm.Interval = 400
    $tm.add_Tick({ foreach ($f in @([Windows.Forms.Application]::OpenForms)) { if ($f.GetType().Name -eq 'SetupWizard' -and $f.Visible) { $script:wizSeen = $f.Text; $f.Close() } } })
    $b = Shot 'Overview assistant before'; $tm.Start(); (Find 'Engine' ([Windows.Forms.Button]) 'Setup assistant...').PerformClick(); $tm.Stop(); Pump 200; $a = Shot 'Overview assistant after'
    Proof 'Overview' "button 'Setup assistant...'" 'click' 'the setup assistant window opens' "opened: '$script:wizSeen'" ($script:wizSeen -ne $null) $b $a

    # ---- Screens
    Open 'Screens'
    if ($script:role -eq 'Server') {
        $sm = Find 'Your monitors' ([object]) $null 0 -ErrorAction SilentlyContinue
        $sm = @(Walk $script:form '' | ? { $_.C.GetType().Name -eq 'ScreenMap' } | % C)[0]
        $hit = $sm.GetType().GetMethod('HitTest', $bf); $pt = $null
        for ($y = 5; $y -lt $sm.Height -and -not $pt; $y += 10) { for ($x = 5; $x -lt $sm.Width; $x += 10) { $p = New-Object Drawing.Point $x, $y; if ($hit.Invoke($sm, @($p)) -ne $null) { $pt = $p; break } } }
        $mon = $hit.Invoke($sm, @($pt))
        $b = Shot 'Screens map before'
        $sm.GetType().GetMethod('OnMouseClick', $bf).Invoke($sm, (Click-Args $pt)); Pump 300
        $item = @($sm.LastMenu.Items | ? { $_.Text -like "Show leet's screen 1*" })[0]
        $item.PerformClick(); Pump 300; $sm.LastMenu.Close(); $a = Shot 'Screens map after'
        $scr = (J)['Screens']; $assigned = ($scr.Keys | % { "$_=$($scr[$_])" }) -join ','
        Proof 'Screens' "monitor map (click a monitor > 'Show leet's screen 1')" "click $mon" "app.json Screens has $mon=1" "Screens: $assigned" ($scr[$mon] -eq 1) $b $a
        $sm.GetType().GetMethod('OnMouseClick', $bf).Invoke($sm, (Click-Args $pt)); Pump 300
        @($sm.LastMenu.Items | ? { $_.Text -eq 'Its own desktop' })[0].PerformClick(); Pump 300; $sm.LastMenu.Close()
        $scr = (J)['Screens']
        Proof 'Screens' "monitor map (click a monitor > 'Its own desktop')" "click $mon" "app.json Screens no longer has $mon" "Screens: $(($scr.Keys | % { "$_=$($scr[$_])" }) -join ',')" (-not $scr.ContainsKey($mon)) $a (Shot 'Screens map own')
        TestCheck 'Picture' 'Interactive: moving the mouse onto a picture works on that computer' 0 'Interactive' $null 'Picture'
    } else {
        foreach ($k in 1..4) {
            Open 'Screens'; $b = Shot "Screens view $k before"
            (Find 'View the server' ([Windows.Forms.Button]) "Its screen $k").PerformClick(); Pump 300; $a = Shot "Screens view $k after"
            Proof 'Screens' "button 'Its screen $k'" 'click' "viewing the server's screen $k" "ClientView=$($engine.S.ClientView)" ($engine.S.ClientView -eq $k) $b $a
        }
        Open 'Screens'; $b = Shot 'Screens back before'; (Find 'View the server' ([Windows.Forms.Button]) 'Back to this computer').PerformClick(); Pump 300; $a = Shot 'Screens back after'
        Proof 'Screens' "button 'Back to this computer'" 'click' 'back on this computer (ClientView=0)' "ClientView=$($engine.S.ClientView)" ($engine.S.ClientView -eq 0) $b $a
    }
    TestCombo 'Picture' 0 'Stretch - fill the monitor' 'Picture' 'Stretch' $null $null 'Picture' 'Picture'
    TestCombo 'Picture' 1 'Wi-Fi - 10 Mbps, steadier' 'Profile' 'WiFi' $null $null 'Picture' 'Quality'
    if ($script:clipOk) {
        Open 'Screens'; $box = Find 'More screens on a laptop' ([Windows.Forms.TextBox]); [Windows.Forms.Clipboard]::SetText('x'); $b = Shot 'Screens copy before'
        (Find 'More screens on a laptop' ([Windows.Forms.Button]) 'Copy command').PerformClick(); Pump 200; $a = Shot 'Screens copy after'
        Proof 'Screens' "button 'Copy command'" 'click' 'the install command is on the clipboard' (Clip) ((Clip) -eq $box.Text -and $box.Text -match 'install\.ps1') $b $a
    }

    # ---- Connection
    $script:page = 'Connection'
    Open 'Connection'; $tb = @(Walk $script:form '' | ? { $_.Card -eq 'Names and address' -and $_.C -is [Windows.Forms.TextBox] -and $_.C.Visible -and $_.C.Parent -isnot [Windows.Forms.NumericUpDown] } | % C)
    $b = Shot 'Connection names before'
    $tb[0].Text = 'QA-DESK2'; $tb[1].Text = 'lap2'; $tb[2].Text = '10.0.0.5'; (Find 'Names and address' ([Windows.Forms.NumericUpDown])).Value = 24811
    SaveOn 'Connection'; $a = Shot 'Connection names after'; $j = J; $ini = Ini
    Proof 'Connection' 'text box: this computer''s name' "'QA-DESK' -> 'QA-DESK2'" 'app.json + engine computerName=QA-DESK2' "app.json $($j['ComputerName']); engine $(IniVal 'computerName')" ($j['ComputerName'] -eq 'QA-DESK2' -and (IniVal 'computerName') -eq 'QA-DESK2') $b $a
    Proof 'Connection' 'text box: other computer''s name' "'leet' -> 'lap2'" $(if ($script:role -eq 'Server') { 'app.json RemoteName=lap2; engine has [computer_lap2]' } else { 'app.json RemoteName=lap2' }) "app.json $($j['RemoteName']); engine section: $([bool]($ini -match '\[computer_lap2\]'))" ($j['RemoteName'] -eq 'lap2' -and ($script:role -eq 'Client' -or $ini -match '\[computer_lap2\]')) $b $a
    Proof 'Connection' 'text box: server address' "-> '10.0.0.5'" 'app.json ServerAddress + engine remoteHost=10.0.0.5' "app.json $($j['ServerAddress']); engine $(IniVal 'remoteHost')" ($j['ServerAddress'] -eq '10.0.0.5' -and (IniVal 'remoteHost') -eq '10.0.0.5') $b $a
    Proof 'Connection' 'number: port' '24800 -> 24811' 'app.json Port + engine port=24811' "app.json $($j['Port']); engine $(IniVal 'port')" ("$($j['Port'])" -eq '24811' -and (IniVal 'port') -eq '24811') $b $a
    if ($script:role -eq 'Server') {
        Open 'Connection'; $c = Find 'Where is the other computer?' ([Windows.Forms.ComboBox]); $b = Shot 'Connection side before'
        $c.SelectedItem = 'Left'; Pump 100; SaveOn 'Connection'; $a = Shot 'Connection side after'
        $lay = [IO.File]::ReadAllText($Core::LayoutPath)
        Proof 'Connection' "list 'Where is the other computer?'" "-> 'Left'" "app.json RemoteSide=Left; layout 'left = lap2'" "app.json $($j = J; $j['RemoteSide']); layout: $([bool]($lay -match 'left = lap2'))" ((J)['RemoteSide'] -eq 1 -and $lay -match 'left = lap2') $b $a
        Open 'Connection'; $oldCode = (J)['PairCode']; $b = Shot 'Connection newcode before'; [DeepAnswerer]::Seen.Clear()
        (Find 'Pairing code' ([Windows.Forms.Button]) 'New code').PerformClick(); Pump 600; SaveOn 'Connection'; $a = Shot 'Connection newcode after'
        $newCode = (J)['PairCode']
        Proof 'Connection' "button 'New code'" 'click, answer Yes' 'asks first, then a new valid 12-character code is saved' "asked: $([DeepAnswerer]::Seen.Count -gt 0); '$oldCode' -> '$newCode'" ([DeepAnswerer]::Seen.Count -gt 0 -and $newCode -ne $oldCode -and $newCode -match '^[2-9A-HJKMNP-Z]{12}$') $b $a
        Open 'Connection'; $b = Shot 'Connection role before'
        (Find 'Role' ([Windows.Forms.RadioButton]) $null 1).Checked = $true; SaveOn 'Connection'; $a = Shot 'Connection role after'
        Proof 'Connection' "radio 'Client'" 'select, save' 'app.json Role=Client; engine coreMode=1' "Role=$((J)['Role']); coreMode=$(IniVal 'coreMode')" ((J)['Role'] -eq 2 -and (IniVal 'coreMode') -eq '1') $b $a
        $engine.S.Role = [Enum]::Parse((T 'DeskView.Role'), 'Server'); $engine.S.Save()
    } else {
        Open 'Connection'; $code = Find 'Pairing code' ([Windows.Forms.TextBox]); $b = Shot 'Connection code before'
        $code.Text = 'abcdefgh23'; SaveOn 'Connection'; $a = Shot 'Connection code after'
        Proof 'Connection' 'text box: pairing code' "-> 'abcdefgh23'" 'app.json PairCode=ABCDEFGH23 (upper case)' "PairCode=$((J)['PairCode'])" ((J)['PairCode'] -eq 'ABCDEFGH23') $b $a
    }

    # ---- Switching & input (classic engine: every option ends up in the engine settings)
    $script:page = 'Switching & input'; $sv = 'Switching & input'
    TestCheck 'Switching between computers' 'on' 0 'SwitchDelayEnabled' 'enableSwitchDelay' $sv
    TestNumber 'Switching between computers' 0 777 'SwitchDelayMs' 777 'switchDelay' 777 $sv 'Wait before switching (ms)'
    TestCheck 'Switching between computers' 'on' 1 'DoubleTapEnabled' 'enableSwitchDoubleTap' $sv
    TestNumber 'Switching between computers' 1 333 'DoubleTapMs' 333 'switchDoubleTap' 333 $sv 'Double-tap (ms)'
    TestCheck 'Switching between computers' 'Lock the mouse to the current computer by default (Scroll Lock toggles)' 0 'DefaultLockToScreen' 'defaultLockToComputerState' $sv
    TestCheck 'Switching between computers' 'Never lock the mouse to one computer' 0 'DisableLockToScreen' 'disableLockToComputer' $sv
    TestCheck 'Switching between computers' 'Relative mouse moves (for games that capture the mouse)' 0 'RelativeMouseMoves' 'relativeMouseMoves' $sv
    TestCheck 'Switching between computers' 'Keep the active window in front on Windows clients' 0 'Win32KeepForeground' 'win32KeepForeground' $sv
    $cornerIni = $script:role -eq 'Server'   # corners and keys are per other computer: only the server writes them
    foreach ($c in @(@('Top left', 'CornerTopLeft', 'switchCornerTopLeft'), @('Top right', 'CornerTopRight', 'switchCornerTopRight'), @('Bottom left', 'CornerBottomLeft', 'switchCornerBottomLeft'), @('Bottom right', 'CornerBottomRight', 'switchCornerBottomRight'))) {
        TestCheck 'Dead corners' $c[0] 0 $c[1] $(if ($cornerIni) { $c[2] } else { $null }) $sv
    }
    TestNumber 'Dead corners' 0 42 'CornerSize' 42 $(if ($cornerIni) { 'switchCornerSize' } else { $null }) 42 $sv 'Corner size'
    $mods = @(@(0, 'ctrl', 'ModifierShift', 'modifierShift'), @(1, 'alt', 'ModifierCtrl', 'modifierCtrl'), @(2, 'meta', 'ModifierAlt', 'modifierAlt'), @(3, 'none', 'ModifierAltGr', 'modifierAltGr'), @(4, 'super', 'ModifierMeta', 'modifierMeta'), @(5, 'shift', 'ModifierSuper', 'modifierSuper'))
    foreach ($m in $mods) { TestCombo 'Keys on the other computer' $m[0] $m[1] $m[2] $m[1] $(if ($cornerIni) { $m[3] } else { $null }) $m[1] $sv "Key $($m[2] -replace 'Modifier', '')" }
    foreach ($c in @(@('Half-duplex Caps Lock', 'HalfDuplexCapsLock', 'halfDuplexCapsLock'), @('Half-duplex Num Lock', 'HalfDuplexNumLock', 'halfDuplexNumLock'), @('Half-duplex Scroll Lock', 'HalfDuplexScrollLock', 'halfDuplexScrollLock'))) {
        TestCheck 'Keys on the other computer' $c[0] 0 $c[1] $(if ($cornerIni) { $c[2] } else { $null }) $sv
    }
    $scrollCard = 'Scrolling and keyboard layout (on this computer as a client)'
    TestCheck $scrollCard 'Invert vertical scrolling' 0 'InvertScrollY' 'invertYScroll' $sv
    TestCheck $scrollCard 'Invert horizontal scrolling' 0 'InvertScrollX' 'invertXScroll' $sv
    TestNumber $scrollCard 0 150 'ScrollScaleY' 1.5 'yScrollScale' 1.5 $sv 'Scroll speed (%)'
    TestCheck $scrollCard "Follow the server's keyboard layout" 0 'LanguageSync' 'languageSync' $sv
    TestCheck 'Clipboard' 'Share the clipboard' 0 'ClipboardEnabled' 'enableClipboard' $sv
    TestNumber 'Clipboard' 0 7 'ClipboardSizeMb' 7 'clipboardSize' 7 $sv 'Largest clipboard (MB)'
    TestCheck 'Mouse pointer' 'Always show the mouse pointer on this computer when it is the client' 0 'AlwaysShowPointer' $null $null
    TestCheck 'Connection health and power' 'on' 0 'HeartbeatEnabled' 'enableHeartbeat' $sv
    TestNumber 'Connection health and power' 0 9000 'HeartbeatMs' 9000 'heartbeat' 9000 $sv 'Dead-connection check (ms)'
    TestCheck 'Connection health and power' 'Keep this computer awake while connected' 0 'PreventSleep' 'preventSleep' $sv
    # engine choice: switching to built-in stops the classic engine and greys out its options; back starts it again
    Open $sv; ClearSent; $c = Find 'Keyboard & mouse engine' ([Windows.Forms.ComboBox]); $b = Shot 'engine builtin before'
    $c.SelectedIndex = 1; Pump 700; $a = Shot 'engine builtin after'
    $greyed = @(Walk $script:form '' | ? { $_.Card -eq 'Switching between computers' -and $_.C -is [Windows.Forms.CheckBox] -and -not $_.C.Enabled }).Count
    $classicRunning = [bool](Get-Process deskflow-core -ErrorAction SilentlyContinue)
    Proof $sv "list 'Keyboard & mouse engine' -> DeskView built-in" 'select' "app.json InputEngine=DeskView; classic-only options greyed out$(if ($classicRunning) { '; engine gets stop' })" "InputEngine=$((J)['InputEngine']); greyed=$greyed; sent=$(Sent)" ((J)['InputEngine'] -eq 'DeskView' -and $greyed -ge 4 -and (-not $classicRunning -or (Sent) -match 'stop')) $b $a
    Open $sv; ClearSent; $c = Find 'Keyboard & mouse engine' ([Windows.Forms.ComboBox]); $b = Shot 'engine classic before'
    $c.SelectedIndex = 0; Pump 700; $a = Shot 'engine classic after'
    $enabled = @(Walk $script:form '' | ? { $_.Card -eq 'Switching between computers' -and $_.C -is [Windows.Forms.CheckBox] -and $_.C.Enabled }).Count
    Proof $sv "list 'Keyboard & mouse engine' -> Classic" 'select' 'app.json InputEngine=Classic; options usable again; engine gets start' "InputEngine=$((J)['InputEngine']); usable=$enabled; sent=$(Sent)" ((J)['InputEngine'] -eq 'Classic' -and $enabled -ge 4 -and (Sent) -match 'start') $b $a

    # ---- Security
    $script:page = 'Security'
    TestCheck 'Keyboard and mouse traffic' 'Encrypt keyboard and mouse traffic (TLS)' 0 'TlsEnabled' 'tlsEnabled' 'Security'
    TestCheck 'Keyboard and mouse traffic' 'Only accept a computer whose fingerprint was trusted' 0 'CheckPeers' 'checkPeerFingerprints' 'Security'

    # ---- Logs
    $script:page = 'Logs'
    TestCombo 'Logs' 0 'DEBUG' 'LogLevel' 'DEBUG' 'level' 'DEBUG' $null 'Engine detail level'
    if ($script:clipOk) {
        Open 'Logs'; $box = @(Walk $script:form '' | ? { $_.C -is [Windows.Forms.TextBox] -and $_.C.Multiline } | % C)[0]; [Windows.Forms.Clipboard]::SetText('x'); $b = Shot 'Logs copy before'
        (Find 'Logs' ([Windows.Forms.Button]) 'Copy').PerformClick(); Pump 200; $a = Shot 'Logs copy after'
        Proof 'Logs' "button 'Copy'" 'click' 'the log text is on the clipboard' "$((Clip).Length) characters" ((Clip) -eq $box.Text -and $box.Text -match '=== DeskView ===') $b $a
    }
    Open 'Logs'; $b = Shot 'Logs folder before'
    $shell = New-Object -ComObject Shell.Application; $leaf = Split-Path $home2 -Leaf
    (Find 'Logs' ([Windows.Forms.Button]) 'Open log folder').PerformClick()
    $win = $null; $end = (Get-Date).AddSeconds(8); while (-not $win -and (Get-Date) -lt $end) { Pump 300; $win = @($shell.Windows() | ? { $_.LocationURL -and [uri]::UnescapeDataString($_.LocationURL) -match [regex]::Escape($leaf) })[0] }
    $a = Shot 'Logs folder after'
    Proof 'Logs' "button 'Open log folder'" 'click' "an Explorer window opens on the settings folder ($leaf)" $(if ($win) { "opened: $([uri]::UnescapeDataString($win.LocationURL))" } else { 'no window' }) ($win -ne $null) $b $a
    if ($win) { $win.Quit() }

    $script:form.Close(); $script:form.Dispose(); Pump 200
}
[DeepAnswerer]::Stop()

# ------------------------------------------------------------------------------------------------- report
$rows = foreach ($r in $script:report) {
    $cls = if ($r.Ok) { 'ok' } else { 'bad' }
    "<tr class='$cls'><td>$(if ($r.Ok) { 'PASS' } else { 'FAIL' })</td><td>$($r.Role)</td><td>$($r.Page)</td><td>$([Net.WebUtility]::HtmlEncode($r.Control))</td><td>$([Net.WebUtility]::HtmlEncode($r.Did))</td><td>$([Net.WebUtility]::HtmlEncode($r.Expected))</td><td>$([Net.WebUtility]::HtmlEncode($r.Actual))</td><td><a href='$($r.Before)'><img src='$($r.Before)'></a></td><td><a href='$($r.After)'><img src='$($r.After)'></a></td></tr>"
}
@"
<!doctype html><meta charset=utf-8><title>DeskView deep GUI test</title>
<style>body{font:14px Segoe UI,sans-serif;margin:20px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 6px;vertical-align:top}tr.ok td:first-child{background:#d7f5dd}tr.bad td:first-child{background:#f8d0d0}img{width:180px}</style>
<h1>DeskView deep GUI test</h1><p>$script:pass passed, $script:fail failed. Every row: the control, what was done, the expected effect, the effect found (app.json / engine settings / engine commands / clipboard / window), with screenshots before and after.</p>
<table><tr><th>Result</th><th>Role</th><th>Page</th><th>Control</th><th>Did</th><th>Expected</th><th>Found</th><th>Before</th><th>After</th></tr>
$($rows -join "`n")
</table>
"@ | Set-Content (Join-Path $shots 'report.html') -Encoding UTF8
[IO.Directory]::Delete($work, $true)
"report: $(Join-Path $shots 'report.html')"
"== gui-deep: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }

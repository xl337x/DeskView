# the server side of the live input test (DeskView started with DESKVIEW_QA_INPUT=1 counts this injected input as real):
# over the right edge to the laptop, click into the text box there, type, copy, come back.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Name M -Namespace X -MemberDefinition @'
[DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
'@
[void][X.M]::SetProcessDpiAwarenessContext([IntPtr](-4))
function T { Get-Date -Format HH:mm:ss.fff }
function Rel($dx, $dy) { [X.M]::mouse_event(1, $dx, $dy, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 15 }
function Key($vk, $up) { [X.M]::keybd_event($vk, 0, $(if ($up) { 2 } else { 0 }), [UIntPtr]::Zero); Start-Sleep -Milliseconds 30 }
function Tap($vk) { Key $vk $false; Key $vk $true }
$clipServer = "QA clipboard from the server $(T)"
[Windows.Forms.Clipboard]::SetText($clipServer); "$(T) the server clipboard set: $clipServer"
$v = [Windows.Forms.SystemInformation]::VirtualScreen
[void][X.M]::SetCursorPos($v.Right - 30, 540); Start-Sleep -Milliseconds 200
"$(T) pushing off the right edge"
for ($i = 0; $i -lt 10; $i++) { Rel 10 0 }
Start-Sleep -Milliseconds 400
"$(T) on the laptop: moving to the text box and clicking"
for ($i = 0; $i -lt 10; $i++) { Rel 8 0 }           # a little way into the laptop (the text box covers its screens 2 and 3)
Start-Sleep -Milliseconds 300
[X.M]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [X.M]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
"$(T) typing"
foreach ($c in 'DESKVIEW'.ToCharArray()) { Tap ([byte][char]$c) }
Key 0x10 $false; Tap 0x31; Key 0x10 $true         # Shift+1 = "!"
Start-Sleep -Milliseconds 300
"$(T) select all + copy on the laptop"
Key 0x10 $false; [X.M]::keybd_event(0x24, 0x47, 1, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30; [X.M]::keybd_event(0x24, 0x47, 3, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30; Key 0x10 $true; Key 0x11 $false; Tap 0x43; Key 0x11 $true   # Shift+Home selects the line, Ctrl+C copies
Start-Sleep -Milliseconds 600
"$(T) coming back over the left edge it entered by"
for ($i = 0; $i -lt 60; $i++) { Rel -25 0 }
Start-Sleep -Milliseconds 1500
"$(T) back on the server at $([Windows.Forms.Cursor]::Position); the server clipboard now: [$([Windows.Forms.Clipboard]::GetText())]"

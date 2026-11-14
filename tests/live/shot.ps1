param([string]$Out = "$PSScriptRoot\shot.png", [int]$Scale = 4)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name D -Namespace X -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);'
[void][X.D]::SetProcessDpiAwarenessContext([IntPtr](-4))
$v = [System.Windows.Forms.SystemInformation]::VirtualScreen
$full = New-Object Drawing.Bitmap $v.Width, $v.Height
[Drawing.Graphics]::FromImage($full).CopyFromScreen($v.X, $v.Y, 0, 0, $v.Size)
$small = New-Object Drawing.Bitmap ([int]($v.Width / $Scale)), ([int]($v.Height / $Scale))
$g = [Drawing.Graphics]::FromImage($small); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($full, 0, 0, $small.Width, $small.Height)
$small.Save($Out); "virtual screen $v -> $Out"

# DeskView - see and use your other computer's screens on any monitor, in both directions.
#
# DeskView runs from source: this launcher compiles app\**\*.cs in memory with the C# compiler that ships with
# Windows (inside Microsoft-signed powershell.exe) and starts it. No .exe, no build tools, nothing to sign.
#
#   DeskView.ps1                start (window; the setup assistant the first time)
#   DeskView.ps1 -Tray          start in the tray only (used at sign-in)
#   DeskView.ps1 -Show 2        tell the running DeskView: show the other computer on monitor 2 ("2=1", "off")
#   DeskView.ps1 -LoadOnly      compile and load only (tests use this to test exactly what users run)
param([string]$Show, [switch]$Tray, [switch]$LoadOnly)

# Locked-down PCs: say so plainly instead of failing with a compiler error.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $msg = "This PC only allows restricted PowerShell (constrained language mode), so DeskView can't run here. Ask IT to allow DeskView, or to sign it."
    if ($LoadOnly) { throw $msg }
    Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg, 'DeskView'); exit 1
}

if (-not ('DeskView.Program' -as [type])) {
    $sources = @(Get-ChildItem $PSScriptRoot -Recurse -Filter *.cs | % FullName)
    $refs = 'System.Windows.Forms', 'System.Drawing', 'System.Web.Extensions', 'System.Management', 'Microsoft.CSharp', 'System.Core'
    try { Add-Type -Path $sources -ReferencedAssemblies $refs -ErrorAction Stop }
    catch {
        $msg = "DeskView could not start: $($_.Exception.Message)"
        if ($LoadOnly) { throw }
        Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg, 'DeskView'); exit 1
    }
}
$env:DESKVIEW_APPDIR = $PSScriptRoot
if ($LoadOnly) { return }

$argv = @()
if ($Tray) { $argv += '--tray' }
if ($Show) { $argv += '--show', $Show }
[DeskView.Program]::Main([string[]]$argv)

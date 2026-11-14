# run a dvqa action on the laptop; prints "<the server time when sent> | <the server time answered> | answer"
param([string]$Action, [string]$A1, [string]$A2, [string]$A3, [string]$A4, [string]$A5)
$t0 = Get-Date -Format HH:mm:ss.fff
$argsLine = @($A1, $A2, $A3, $A4, $A5) | ? { $_ } | % { if ($_ -match '\s') { '\"' + $_ + '\"' } else { $_ } }
$r = ssh -i $env:DV_SSHKEY$1 $env:DV_LAPTOP "powershell -NoProfile -OutputFormat Text -ExecutionPolicy Bypass -File C:\Users\Public\laptop-dvqa.ps1 $Action $($argsLine -join ' ')" 2>$null
"$t0 | $(Get-Date -Format HH:mm:ss.fff) | $($r -join ' ')"

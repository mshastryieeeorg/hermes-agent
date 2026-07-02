# Detects divergence between the two local copies of the main website source:
# D:\GitHub\fluffy (canonical) vs D:\GitHub\fluffy-hermes. Deploying from the
# stale copy is a real risk; this flags it before it happens.
# Exit 0 = identical; 1 = drift.

$a = "D:\GitHub\fluffy\Website\Website_Finished_13"
$b = "D:\GitHub\fluffy-hermes\Website\Website_Finished_13"
if (-not (Test-Path $b)) { Write-Output "fluffy-hermes copy not present - nothing to drift."; exit 0 }

$diff = & git diff --no-index --stat --diff-filter=ACDMR -- $a $b 2>$null | Select-Object -Last 12
if (-not $diff) { Write-Output "In sync: fluffy and fluffy-hermes website trees are identical."; exit 0 }

Write-Output "DRIFT between fluffy and fluffy-hermes website trees (canonical = fluffy):"
$diff | ForEach-Object { Write-Output "  $_" }
Write-Output "Do NOT deploy from fluffy-hermes; reconcile or delete the stale copy."
exit 1

# Stripe <-> D1 reconciliation for kalman-commons (read-only).
# Flags paid Stripe Checkout sessions with no matching ACTIVE member row (stranded members).
# Exit 0 = reconciled; 1 = discrepancies found; 2 = could not run.
param([int]$Days = 8)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$stripeKey = (Get-Content "D:\CFConfig\stripe-secret-key.txt" -Raw).Trim()
$since = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToUnixTimeSeconds()

# Paid checkout sessions from Stripe (paginated).
$sessions = @(); $url = "https://api.stripe.com/v1/checkout/sessions?limit=100&created[gte]=$since"
while ($url) {
    $page = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $stripeKey" }
    $sessions += $page.data
    $url = if ($page.has_more) { "https://api.stripe.com/v1/checkout/sessions?limit=100&created[gte]=$since&starting_after=$($page.data[-1].id)" } else { $null }
}
$paid = @($sessions | Where-Object { $_.payment_status -eq "paid" })
Write-Output "Stripe: $($sessions.Count) checkout sessions in last $Days days, $($paid.Count) paid."

# Active members from D1 (wrangler uses the cached OAuth login; API token lacks D1).
$env:CLOUDFLARE_API_TOKEN = $null
$raw = & D:\Tools\npm-global\wrangler.cmd d1 execute kalman_commons_intake --remote --json --command "SELECT stripe_session_id, email, status FROM members WHERE created_at >= datetime('now', '-$Days days')" 2>$null | Out-String
$start = $raw.IndexOf('['); if ($start -lt 0) { Write-Output "FAIL: no JSON from wrangler d1"; exit 2 }
$rows = (ConvertFrom-Json $raw.Substring($start))[0].results
Write-Output "D1: $($rows.Count) member rows in the window."

$bad = @()
foreach ($s in $paid) {
    $m = $rows | Where-Object { $_.stripe_session_id -eq $s.id }
    if (-not $m) { $bad += "PAID session $($s.id) ($($s.customer_details.email)): NO member row" }
    elseif ($m.status -ne "active") { $bad += "PAID session $($s.id) ($($m.email)): member status='$($m.status)' (expected active)" }
}
if ($bad.Count) {
    Write-Output "DISCREPANCIES ($($bad.Count)) - P1, see exception-handling.md triage step 4:"
    $bad | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output "Reconciled: every paid session has an active member row."
exit 0

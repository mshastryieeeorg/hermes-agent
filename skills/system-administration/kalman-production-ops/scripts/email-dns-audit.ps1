# Email deliverability DNS audit (read-only): SPF / DMARC / MX for the domains
# used by Resend (no-reply@kalman-systems.com.au) and Email Routing (groups.*).
# Exit 0 = all present; 1 = something missing.

$fail = 0
function Check-Txt([string]$name, [string]$mustMatch, [string]$label) {
    $txt = (Resolve-DnsName $name -Type TXT -Server 1.1.1.1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Strings -join "" }) -join " | "
    if ($txt -and $txt -match $mustMatch) { Write-Output "OK: $label ($name)"; return }
    Write-Output "MISSING: $label - no TXT at $name matching '$mustMatch' (found: '$txt')"
    $script:fail++
}
function Check-Mx([string]$name, [string]$label) {
    $mx = Resolve-DnsName $name -Type MX -Server 1.1.1.1 -ErrorAction SilentlyContinue | Where-Object { $_.NameExchange }
    if ($mx) { Write-Output "OK: $label MX -> $(($mx | ForEach-Object NameExchange) -join ', ')"; return }
    Write-Output "MISSING: $label - no MX records at $name"
    $script:fail++
}

Write-Output "=== kalman-systems.com.au (Resend sender + groups) ==="
Check-Txt "kalman-systems.com.au" "v=spf1" "SPF"
Check-Txt "_dmarc.kalman-systems.com.au" "v=DMARC1" "DMARC"
Check-Mx  "groups.kalman-systems.com.au" "groups (Email Routing)"

Write-Output "=== kalmansystems.com.au ==="
Check-Txt "kalmansystems.com.au" "v=spf1" "SPF"
Check-Txt "_dmarc.kalmansystems.com.au" "v=DMARC1" "DMARC"

Write-Output ""
if ($fail) { Write-Output "$fail email-DNS items missing - login links / group mail may be failing or spam-foldered. See system-administration.md Email Routing."; exit 1 }
Write-Output "Email DNS complete."
exit 0

# One-time: create Cloudflare-native notification policies (email to the account owner).
# ALL FOUR POLICIES CREATED 2026-07-02 (via global key). This script remains for
# re-creation after account changes; it is idempotent (skips existing names).
# Requires account "Notification Services: Edit" on the token.
# NOTE: pages_event_alert requires project UUIDs (not names) and an environment filter.

$ErrorActionPreference = "Stop"
$acct = "a6bed40bd99b2dd2ef5716f9c270e5ca"
$token = (Get-Content "D:\CFConfig\cloudflare-api-token.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$base = "https://api.cloudflare.com/client/v4/accounts/$acct/alerting/v3/policies"
$mech = @{ email = @(@{ id = "shastry.mahesh@gmail.com" }) }

$existing = (Invoke-RestMethod -Uri $base -Headers $headers).result | ForEach-Object name

$policies = @(
    @{ name = "Kalman: Pages deployment failures"; alert_type = "pages_event_alert"; enabled = $true; mechanisms = $mech;
       filters = @{ environment = @("ENVIRONMENT_PRODUCTION"); event = @("EVENT_DEPLOYMENT_FAILED");
                    project_id = @("717004e0-ba63-497d-990e-7a37a83e5962", "a889816a-a343-4f29-9282-11e8f536a24c") };
       description = "Deploy failed on either Kalman Pages project (UUIDs: kalman-commons, kalman-systems-website)" },
    @{ name = "Kalman: Universal SSL certificate events"; alert_type = "universal_ssl_event_type"; enabled = $true; mechanisms = $mech;
       description = "Universal SSL validation/issuance/expiry events" },
    @{ name = "Kalman: HTTP DDoS attack detected"; alert_type = "dos_attack_l7"; enabled = $true; mechanisms = $mech;
       description = "L7 DDoS mitigation triggered on a Kalman zone" },
    @{ name = "Kalman: Cloudflare incidents (SYD)"; alert_type = "incident_alert"; enabled = $true; mechanisms = $mech;
       filters = @{ airport_code = @("SYD") };
       description = "Cloudflare incidents affecting the Sydney PoP" }
)

foreach ($p in $policies) {
    if ($existing -contains $p.name) { Write-Output "SKIP (exists): $($p.name)"; continue }
    try {
        $r = Invoke-RestMethod -Method Post -Uri $base -Headers $headers -Body ($p | ConvertTo-Json -Depth 6)
        Write-Output "CREATED: $($p.name) (id $($r.result.id))"
    } catch {
        Write-Output "FAILED: $($p.name) - $($_.Exception.Message). Token likely still lacks Notification Services: Edit."
    }
}
Write-Output "Note: first email delivery requires confirming the verification email Cloudflare sends to shastry.mahesh@gmail.com."

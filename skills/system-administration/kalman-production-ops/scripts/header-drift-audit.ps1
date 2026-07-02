# Compares live security headers on both sites against the _headers files in the
# source repos. Catches CSP drift, which breaks forms with no server-side error.
# Exit 0 = in sync; 1 = drift detected.

$ErrorActionPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 KalmanHeaderAudit/1.0"
$watched = @("Content-Security-Policy", "Strict-Transport-Security", "X-Frame-Options", "X-Content-Type-Options", "Referrer-Policy", "Permissions-Policy")

function Get-ExpectedHeaders([string]$file) {
    # Parse the "/*" (or "/") block of a Cloudflare Pages _headers file.
    $expected = @{}; $inBlock = $false
    foreach ($line in Get-Content $file) {
        if ($line -match "^\S") { $inBlock = ($line.Trim() -eq "/*" -or $line.Trim() -eq "/") ; continue }
        if ($inBlock -and $line -match "^\s+([\w-]+):\s*(.+)$") { $expected[$Matches[1]] = $Matches[2].Trim() }
    }
    return $expected
}

$targets = @(
    @{ Name = "kalmansystems.com.au"; Url = "https://kalmansystems.com.au/"; File = "D:\GitHub\fluffy\Website\Website_Finished_13\_headers" },
    @{ Name = "kalman-commons"; Url = "https://kalman-commons.pages.dev/"; File = "D:\GitHub\cigars\site\_headers" }
)

$drift = 0
foreach ($t in $targets) {
    Write-Output "=== $($t.Name) ==="
    $expected = Get-ExpectedHeaders $t.File
    try { $resp = Invoke-WebRequest -Uri $t.Url -UserAgent $UA -MaximumRedirection 2 -UseBasicParsing -TimeoutSec 20 } catch { Write-Output "  FETCH FAILED: $($_.Exception.Message)"; $drift++; continue }
    foreach ($h in $watched) {
        $exp = $expected[$h]; $live = $resp.Headers[$h]
        if (-not $exp) { continue }
        if (-not $live) { Write-Output "  DRIFT: $h missing live (repo expects it)"; $drift++ }
        elseif (($live | Out-String).Trim() -ne $exp) { Write-Output "  DRIFT: $h differs"; Write-Output "    repo: $exp"; Write-Output "    live: $(($live | Out-String).Trim())"; $drift++ }
        else { Write-Output "  OK: $h" }
    }
}
Write-Output ""
if ($drift) { Write-Output "DRIFT ITEMS: $drift - live headers do not match repo _headers. A pending deploy or an unexpected change."; exit 1 }
Write-Output "All watched headers in sync with repos."
exit 0

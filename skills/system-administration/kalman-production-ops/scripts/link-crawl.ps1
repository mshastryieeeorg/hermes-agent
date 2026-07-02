# Sitemap + broken-link check for both sites (read-only, GET only).
# Fetches each site's sitemap.xml and verifies every listed URL returns 200.
# Exit 0 = all URLs healthy; 1 = failures.

$ErrorActionPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 KalmanLinkCrawl/1.0"

# Sitemaps use hashed filenames (robots.txt has no Sitemap: pointer - known SEO gap).
$sitemaps = @(
    "https://kalmansystems.com.au/sitemap-9ea7704bf3211379.xml",
    "https://kalman-commons.pages.dev/sitemap-27ef52b969320e8a.xml"
)
# BOM guard: strip anything before '<' so [xml] casts cleanly.
$fail = 0; $checked = 0
foreach ($sm in $sitemaps) {
    Write-Output "=== $sm ==="
    try {
        $body = (Invoke-WebRequest -Uri $sm -UserAgent $UA -UseBasicParsing -TimeoutSec 20).Content
        $lt = $body.IndexOf("<"); if ($lt -gt 0) { $body = $body.Substring($lt) }
        if ($body -notmatch "^\s*<\?xml|^\s*<urlset") { Write-Output "  NOT XML: $sm returned HTML - sitemap missing at this path"; $fail++; continue }
        [xml]$xml = $body
    }
    catch { Write-Output "  SITEMAP FETCH FAILED: $($_.Exception.Message)"; $fail++; continue }
    $urls = @($xml.urlset.url.loc)
    foreach ($u in $urls) {
        $checked++
        # curl -L: PS 5.1 does not follow 308s (Pages redirects .html -> extensionless).
        $code = (& curl.exe -s -o NUL -w "%{http_code}" -L --max-redirs 4 -A $UA --max-time 20 $u)
        if ($code -ne "200") { Write-Output "  BAD [$code] $u"; $fail++ }
    }
    Write-Output "  $($urls.Count) URLs checked."
}
Write-Output ""
Write-Output "Total: $checked URLs, $fail failures."
if ($fail) { exit 1 } else { exit 0 }

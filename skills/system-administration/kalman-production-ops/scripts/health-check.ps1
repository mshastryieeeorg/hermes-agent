# Kalman production health check — read-only, safe to run any time.
# Exit 0 = all green. Exit 1 = at least one FAIL (known-gap checks report WARN, not FAIL).
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 KalmanHealthCheck/1.0"

$results = New-Object System.Collections.ArrayList
function Add-Result([string]$name, [string]$status, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Check = $name; Status = $status; Detail = $detail })
}

function Test-Http([string]$name, [string]$url, [int[]]$okCodes, [switch]$KnownGap) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = $UA
        $req.Method = "GET"
        $req.Timeout = 20000
        $req.AllowAutoRedirect = $true
        try {
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            else { throw }
        }
        if ($okCodes -contains $code) { Add-Result $name "OK" "HTTP $code" }
        elseif ($KnownGap) { Add-Result $name "WARN" "HTTP $code (known gap)" }
        else { Add-Result $name "FAIL" "HTTP $code (expected $($okCodes -join '/'))" }
    } catch {
        $msg = $_.Exception.Message -replace "`r`n", " "
        if ($KnownGap) { Add-Result $name "WARN" "$msg (known gap: domain not attached)" }
        else { Add-Result $name "FAIL" $msg }
    }
}

function Test-CertExpiry([string]$name, [string]$hostname, [switch]$KnownGap) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostname, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(10000)) { throw "TCP connect timeout" }
        $client.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($hostname)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
        $ssl.Dispose(); $client.Close()
        if ($days -lt 7) { Add-Result $name "FAIL" "certificate expires in $days days ($($cert.NotAfter.ToString('yyyy-MM-dd')))" }
        elseif ($days -lt 21) { Add-Result $name "WARN" "certificate expires in $days days ($($cert.NotAfter.ToString('yyyy-MM-dd')))" }
        else { Add-Result $name "OK" "certificate valid $days more days" }
    } catch {
        $msg = $_.Exception.Message -replace "`r`n", " "
        if ($KnownGap) { Add-Result $name "WARN" "$msg (known gap)" }
        else { Add-Result $name "FAIL" $msg }
    }
}

# --- Main site: Kalman | Systems+ -------------------------------------------
Test-Http "kalmansystems.com.au"        "https://kalmansystems.com.au"        @(200)
Test-Http "www.kalmansystems.com.au"    "https://www.kalmansystems.com.au"    @(200)
Test-Http "pages: kalman-systems-website" "https://kalman-systems-website.pages.dev" @(200)
# Workers expose GET /api/health (200 = D1 probe OK, 503 = worker up but D1 failing).
Test-Http "worker: kalman-requirements-api /api/health" "https://kalman-requirements-api.shastry-mahesh.workers.dev/api/health" @(200)
Test-CertExpiry "cert: kalmansystems.com.au" "kalmansystems.com.au"

# --- Kalman Commons ----------------------------------------------------------
# Domain live since 2026-07-02; www canonically 301s to apex.
Test-Http "kalman-systems.com.au"       "https://kalman-systems.com.au"       @(200)
Test-Http "www.kalman-systems.com.au (301->apex)" "https://www.kalman-systems.com.au" @(200, 301)
Test-Http "pages: kalman-commons"       "https://kalman-commons.pages.dev"    @(200)
Test-Http "worker: kalman-commons-intake /api/health" "https://kalman-commons-intake.shastry-mahesh.workers.dev/api/health" @(200)
Test-CertExpiry "cert: kalman-commons.pages.dev" "kalman-commons.pages.dev"

# --- Report -------------------------------------------------------------------
$results | Format-Table -AutoSize | Out-String | Write-Output
$fails = @($results | Where-Object Status -eq "FAIL")
$warns = @($results | Where-Object Status -eq "WARN")
Write-Output ("Summary: {0} OK, {1} WARN, {2} FAIL ({3} UTC)" -f `
    @($results | Where-Object Status -eq "OK").Count, $warns.Count, $fails.Count, (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm"))
if ($fails.Count -gt 0) { exit 1 } else { exit 0 }

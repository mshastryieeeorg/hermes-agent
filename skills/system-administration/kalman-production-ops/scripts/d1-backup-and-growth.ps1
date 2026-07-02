# Daily D1 backup + growth report for both production databases (read-only + export).
# Exports to D:\CFConfig\backups\d1\ and reports row counts. Prunes backups older than 60 days.
# Exit 0 = both backups valid; 1 = a backup failed or is empty.

$ErrorActionPreference = "SilentlyContinue"
$wrangler = "D:\Tools\npm-global\wrangler.cmd"
$outDir = "D:\CFConfig\backups\d1"
New-Item -ItemType Directory -Force $outDir | Out-Null
$env:CLOUDFLARE_API_TOKEN = $null   # use cached OAuth; the API token lacks D1
$stamp = Get-Date -Format yyyyMMdd-HHmm
$fail = 0

$dbs = @(
    @{ Name = "kalman_commons_intake"; Counts = "SELECT (SELECT COUNT(*) FROM members) AS members, (SELECT COUNT(*) FROM forum_posts) AS forum_posts, (SELECT COUNT(*) FROM rate_limits) AS rate_limits" },
    @{ Name = "kalman_requirements"; Counts = "SELECT (SELECT COUNT(*) FROM submissions) AS submissions, (SELECT COUNT(*) FROM rate_limits) AS rate_limits" }
)

foreach ($db in $dbs) {
    $file = Join-Path $outDir "$($db.Name)-$stamp.sql"
    & $wrangler d1 export $db.Name --remote --output $file 2>$null | Out-Null
    $ok = (Test-Path $file) -and ((Get-Item $file).Length -gt 200) -and (Select-String -Path $file -Pattern "CREATE TABLE" -Quiet)
    if ($ok) { Write-Output "BACKUP OK: $($db.Name) -> $file ($([math]::Round((Get-Item $file).Length/1KB)) KB)" }
    else { Write-Output "BACKUP FAILED: $($db.Name) (missing/empty/no DDL)"; $fail++ }

    $raw = & $wrangler d1 execute $db.Name --remote --json --command $db.Counts 2>$null | Out-String
    $start = $raw.IndexOf('[')
    if ($start -ge 0) {
        $res = (ConvertFrom-Json $raw.Substring($start))[0].results[0]
        $res.PSObject.Properties | ForEach-Object { Write-Output "  rows: $($_.Name) = $($_.Value)" }
    } else { Write-Output "  growth query failed" }
}

# Retention: keep 60 days of backups.
Get-ChildItem $outDir -Filter "*.sql" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } | Remove-Item -Force
Write-Output ("Backups on disk: {0}" -f (Get-ChildItem $outDir -Filter "*.sql").Count)
if ($fail) { exit 1 } else { exit 0 }

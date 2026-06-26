# ============================================================================
# Register-HermesBootTask.ps1 -- Run the Hermes gateway automatically
# ============================================================================
# Registers a Windows Scheduled Task that launches `hermes gateway` so your
# bot comes back online by itself after a reboot / login.
#
# The gateway is the long-running process that handles messaging platforms
# (Telegram/Discord/Slack/WhatsApp) and cron job execution. The installer
# (install.ps1, Start-GatewayIfConfigured) only starts it once for the
# current session -- it does NOT survive a reboot. This script fills that
# gap by creating a real, persistent Scheduled Task.
#
# Usage (from an ordinary PowerShell window, in any directory):
#   powershell -ExecutionPolicy Bypass -File scripts\Register-HermesBootTask.ps1
#
#   # Run before any user logs in (runs as SYSTEM -- needs an *elevated*
#   # PowerShell, i.e. "Run as administrator"):
#   powershell -ExecutionPolicy Bypass -File scripts\Register-HermesBootTask.ps1 -AtBoot
#
#   # Remove the task again:
#   powershell -ExecutionPolicy Bypass -File scripts\Register-HermesBootTask.ps1 -Unregister
#
# Default trigger is "at user logon" running in *your* account -- this is the
# recommended mode because the gateway reads your config + tokens from
# %LOCALAPPDATA%\hermes, which only exists in your user profile. -AtBoot runs
# as SYSTEM before login; only use it if HERMES_HOME points somewhere the
# SYSTEM account can read.
# ============================================================================

param(
    # Where Hermes keeps its config/.env/logs. Mirrors install.ps1's default.
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "$env:LOCALAPPDATA\hermes" }),

    # Where the repo + venv live. Mirrors install.ps1's default.
    [string]$InstallDir = $(if ($env:HERMES_HOME) { "$env:HERMES_HOME\hermes-agent" } else { "$env:LOCALAPPDATA\hermes\hermes-agent" }),

    # Name the task appears under in Task Scheduler.
    [string]$TaskName = "HermesGateway",

    # Trigger at machine startup (runs as SYSTEM, needs admin) instead of the
    # default "at logon, as the current user".
    [switch]$AtBoot,

    # Remove the task instead of creating it.
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

# --- Tiny logging helpers (same look as install.ps1) ------------------------
function Write-Info    { param([string]$Message) Write-Host "-> $Message"   -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[!] $Message"  -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host "[X] $Message"  -ForegroundColor Red }

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Unregister path: tear down and exit.
# ---------------------------------------------------------------------------
if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Info "No scheduled task named '$TaskName' found. Nothing to do."
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Success "Removed scheduled task '$TaskName'."
    return
}

# ---------------------------------------------------------------------------
# Locate hermes.exe. Prefer the venv copy the installer creates; fall back to
# whatever is on PATH.
# ---------------------------------------------------------------------------
$hermesExe = Join-Path $InstallDir "venv\Scripts\hermes.exe"
if (-not (Test-Path $hermesExe)) {
    $onPath = Get-Command hermes -ErrorAction SilentlyContinue
    if ($onPath) {
        $hermesExe = $onPath.Source
    } else {
        Write-Err "Could not find hermes.exe."
        Write-Err "Looked for: $hermesExe"
        Write-Err "And 'hermes' was not on PATH. Has install.ps1 finished successfully?"
        Write-Err "If Hermes lives elsewhere, pass -InstallDir <path-to-hermes-agent>."
        exit 1
    }
}
Write-Info "Using gateway binary: $hermesExe"

# Logs land alongside the installer's gateway logs.
$logDir = Join-Path $HermesHome "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir "gateway-boottask.log"

# ---------------------------------------------------------------------------
# Build the action. We launch via powershell.exe so we can (a) pin HERMES_HOME
# for the spawned process and (b) capture stdout+stderr into one log file --
# a raw Scheduled-Task action can't do either. The escaped quotes keep paths
# with spaces intact inside the -Command string.
# ---------------------------------------------------------------------------
$inner = "`$env:HERMES_HOME = '$HermesHome'; & '$hermesExe' gateway *>> '$logFile'"
$actionArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs -WorkingDirectory $InstallDir

# ---------------------------------------------------------------------------
# Trigger + principal.
# ---------------------------------------------------------------------------
if ($AtBoot) {
    if (-not (Test-IsAdmin)) {
        Write-Err "-AtBoot registers a SYSTEM task, which requires Administrator rights."
        Write-Err "Re-run from an elevated PowerShell (Run as administrator), or drop"
        Write-Err "-AtBoot to register a per-user 'at logon' task instead."
        exit 1
    }
    $trigger = New-ScheduledTaskTrigger -AtStartup
    # SYSTEM = S-1-5-18. Highest run level, no password needed.
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $triggerDesc = "at system startup (as SYSTEM)"
    Write-Warn "SYSTEM cannot read your user profile. Make sure HERMES_HOME ($HermesHome)"
    Write-Warn "is readable by the SYSTEM account, or the gateway won't find your tokens."
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # Current user, but S4U ("Service For User") logon type -- runs the task in
    # the background ("run whether the user is logged on or not") WITHOUT a
    # stored password. The key win over -LogonType Interactive: an S4U task
    # runs in a non-interactive session, so the gateway's console window never
    # appears on the desktop. Outbound network (Telegram/Discord/etc. APIs)
    # still works because that doesn't need the user's Windows credentials.
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Limited
    $triggerDesc = "at logon (as $currentUser, background/no window)"
}

# ---------------------------------------------------------------------------
# Settings: survive flaky boots, never time out, restart on crash, run on
# battery. The gateway is meant to stay up indefinitely.
# ---------------------------------------------------------------------------
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)   # 0 = no limit

# ---------------------------------------------------------------------------
# Register (idempotent: -Force replaces any existing task of the same name).
# ---------------------------------------------------------------------------
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Starts the Hermes gateway (messaging + cron). Created by Register-HermesBootTask.ps1." `
    -Force | Out-Null

Write-Success "Registered scheduled task '$TaskName' -- runs $triggerDesc."
Write-Info "Gateway logs: $logFile"
Write-Host ""
Write-Info "Start it now without rebooting:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Info "Check status:                     Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Info "Remove it later:                  .\scripts\Register-HermesBootTask.ps1 -Unregister"

# Steroid installer — Windows (PowerShell 5.1+)
# Usage: iex (irm 'https://cli.steroidkit.com/install.ps1')
#Requires -Version 5.1
param([switch]$Force)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GITHUB_RELEASES_REPO = "steroidkit/releases"
$InstallDir  = Join-Path $env:USERPROFILE ".steroid\bin"
$WrapperDir  = Join-Path $env:USERPROFILE ".local\bin"
$BinaryName  = "steroid-windows-x86_64.exe"

function Write-Header {
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │              Steroid Installer                  │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Ok   { param($Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Info { param($Msg) Write-Host "  ... $Msg" }
function Write-Fail { param($Msg) Write-Host "  [ERR] $Msg" -ForegroundColor Red; exit 1 }

function Get-InstalledVersion {
    # Read the version stamp a previous install wrote (bare, e.g. 0.3.0), or
    # $null if absent. A file (not `steroid --version`) so we never execute an
    # old/broken binary and there are no side effects.
    $stamp = Join-Path $InstallDir ".version"
    if (-not (Test-Path -LiteralPath $stamp)) { return $null }
    $ver = ((Get-Content -LiteralPath $stamp -Raw).Trim() -replace '^v', '')
    # Self-heal: an older steroid updater could stamp .version even when its
    # swap of steroid.exe failed. If the stamped version's own copy differs
    # from the live binary, report "unknown" so this run repairs it instead
    # of saying "already installed".
    $live = Join-Path $InstallDir "steroid.exe"
    $copy = Join-Path $env:USERPROFILE ".steroid\versions\$ver\steroid.exe"
    if ((Test-Path -LiteralPath $copy) -and (Test-Path -LiteralPath $live)) {
        try {
            if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash) {
                return $null
            }
        } catch { }
    }
    return $ver
}

# ── Check connectivity ───────────────────────────────────────────────────────

function Test-Connectivity {
    Write-Info "Checking internet connectivity..."
    try {
        # Probe github.com (web), NOT api.github.com — the GitHub API is blocked /
        # rate-limited on many corporate VPNs, while web + release downloads are not.
        $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -TimeoutSec 5 -UseBasicParsing
        Write-Ok "Internet reachable"
    } catch {
        Write-Fail "Cannot reach github.com. Check your network connection."
    }
}

# ── Fetch latest version ─────────────────────────────────────────────────────

function Get-LatestVersion {
    Write-Info "Fetching latest Steroid release..."
    # Resolve the version from the /releases/latest redirect
    # (Location: .../releases/tag/<version>) — NOT the GitHub API, which is
    # blocked / rate-limited on some corporate networks. Display only; the binary
    # downloads via the latest/download redirect below.
    #
    # Use System.Net.WebRequest with redirects disabled: it behaves consistently
    # on Windows PowerShell 5.1 AND PowerShell 7. (Invoke-WebRequest
    # -MaximumRedirection 0 differs between the two — the exception shape /
    # response-header access varies — which under Set-StrictMode threw
    # "The property 'Response' cannot be found".) A 3xx with AllowAutoRedirect
    # disabled is returned, not thrown; the catch is a safety net for 4xx/5xx.
    $loc = $null
    try {
        # Ensure TLS 1.2 — Windows PowerShell 5.1's raw HttpWebRequest can default
        # to a protocol GitHub rejects.
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $req = [System.Net.WebRequest]::Create("https://github.com/$GITHUB_RELEASES_REPO/releases/latest")
        $req.Method = "HEAD"
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $loc = $resp.Headers["Location"]
        $resp.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $loc = $_.Exception.Response.Headers["Location"] }
    }
    if ($loc) { $script:LatestVersion = (([string]$loc) -split '/tag/')[-1] }
    if (-not $script:LatestVersion) { Write-Fail "Could not determine latest version." }
    Write-Ok "Latest version: $($script:LatestVersion)"
}

# ── Download + verify ────────────────────────────────────────────────────────

function Download-Binary {
    # latest/download resolves the newest release server-side — no API, no
    # version pinning needed in the URL.
    $BaseUrl = "https://github.com/$GITHUB_RELEASES_REPO/releases/latest/download"
    $script:TmpDir = [System.IO.Path]::GetTempPath() | Join-Path -ChildPath ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    $script:TmpBinary   = Join-Path $script:TmpDir $BinaryName
    $script:TmpChecksum = Join-Path $script:TmpDir "$BinaryName.sha256"

    Write-Info "Downloading $BinaryName..."
    Invoke-WebRequest "$BaseUrl/$BinaryName" -OutFile $script:TmpBinary -UseBasicParsing

    Write-Info "Verifying checksum..."
    # Mandatory, not best-effort: every build (CI for Linux, scripts/build-local.sh
    # / .ps1 for macOS/Windows) computes a .sha256 alongside its binary, so a
    # missing one means the release upload step was incomplete, not that no
    # checksum was ever produced — worth aborting over, not silently installing
    # an unverified binary.
    try {
        Invoke-WebRequest "$BaseUrl/$BinaryName.sha256" -OutFile $script:TmpChecksum -UseBasicParsing
    } catch {
        Write-Fail "No checksum published for this release — refusing to install an unverified binary."
    }
    $Expected = (Get-Content $script:TmpChecksum -Raw).Trim().Split()[0].ToLower()
    $Actual   = (Get-FileHash $script:TmpBinary -Algorithm SHA256).Hash.ToLower()
    if ($Actual -ne $Expected) {
        Write-Fail "Checksum mismatch — binary may be corrupted."
    }
    $script:ExpectedHash = $Expected
    Write-Ok "Checksum verified"
}

# ── Install binary ────────────────────────────────────────────────────────────
#
# Layout: a full copy of each version lives at
# ~/.steroid/versions/<bare-ver>/steroid.exe (kept for rollback by
# Prune-OldVersions), and Dest (~/.steroid/bin/steroid.exe) is a second,
# independent copy of the active one. Every IDE's MCP config, the Scheduled
# Task, and steroid.bat below all hardcode Dest as a fixed path, so it must
# stay in place — unlike macOS/Linux (core/binary_swap.py), Windows can't
# repoint it at the versioned copy via a symlink without elevated privileges
# or Developer Mode, hence the second copy rather than a move or link.
#
# A running steroid.exe (the daemon, any agent's `steroid mcp-server`) can't be
# overwritten or deleted, but it CAN be renamed: the live copy is renamed
# aside and the new one renamed into place — the same approach steroid's own
# updater uses (core/binary_swap.py swap_windows_in_place). Running copies
# keep the renamed file; nothing is stopped first, so a failed swap never
# leaves the daemon stopped. A daemon that was running is restarted
# afterwards so it moves onto the new binary.

$KeepVersions = 2
$DaemonTaskName = "com.steroid.pullserver"

function Move-WithRetry {
    param([string]$From, [string]$To)
    # Antivirus scans briefly lock freshly written executables — retry ~2.5s.
    for ($i = 0; $i -lt 10; $i++) {
        try { Move-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop; return }
        catch { if ($i -eq 9) { throw }; Start-Sleep -Milliseconds 250 }
    }
}

function Get-DaemonTaskState {
    # Locale-independent: the State enum names don't change with the Windows
    # display language (schtasks' text output does). '' if unknown/absent.
    try { return [string](Get-ScheduledTask -TaskName $DaemonTaskName -ErrorAction Stop).State }
    catch { return '' }
}

function Restart-DaemonTask {
    # Only a daemon that is running now; a fresh install's task is registered
    # later (TUI / `steroid setup`), and a Disabled task is left alone.
    if (@('Running', 'Queued') -notcontains (Get-DaemonTaskState)) { return }
    try {
        Stop-ScheduledTask -TaskName $DaemonTaskName -ErrorAction Stop
        for ($i = 0; $i -lt 20 -and (Get-DaemonTaskState) -eq 'Running'; $i++) {
            Start-Sleep -Milliseconds 500
        }
    } catch {
        # Couldn't stop it — still try to start below.
    } finally {
        try {
            Start-ScheduledTask -TaskName $DaemonTaskName -ErrorAction Stop
            Write-Ok "Restarted the background daemon"
        } catch {
            Write-Info "Couldn't restart the background daemon — run 'steroid daemon start'."
        }
    }
}

function Install-Binary {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Dest = Join-Path $InstallDir "steroid.exe"
    $VersionsDir = Join-Path $env:USERPROFILE ".steroid\versions"
    # Captured BEFORE creating anything below: true only the very first time
    # this versioned scheme runs on a machine that already had a (pre-scheme)
    # flat install — used to archive that old binary instead of silently
    # discarding it.
    $IsFirstVersionedInstall = (Test-Path -LiteralPath $Dest) -and -not (Test-Path -LiteralPath $VersionsDir)

    $VersionBare = $script:LatestVersion -replace '^v', ''
    $VersionDir = Join-Path $VersionsDir $VersionBare
    New-Item -ItemType Directory -Force -Path $VersionDir | Out-Null
    $VersionDest = Join-Path $VersionDir "steroid.exe"
    Copy-Item -LiteralPath $script:TmpBinary -Destination $VersionDest -Force
    # Same checksum sidecar steroid's own updater writes, so it recognises
    # this exact build as already staged.
    Set-Content -LiteralPath (Join-Path $VersionDir ".sha256") -Value $script:ExpectedHash -Encoding ASCII

    if ($IsFirstVersionedInstall) {
        $LegacyDir = Join-Path $VersionsDir "legacy"
        New-Item -ItemType Directory -Force -Path $LegacyDir | Out-Null
        Copy-Item -LiteralPath $Dest -Destination (Join-Path $LegacyDir "steroid.exe") -Force -ErrorAction SilentlyContinue
    }

    # Leftovers from earlier swaps; one an agent still runs is skipped.
    Get-ChildItem -LiteralPath $InstallDir -Filter 'steroid.exe.old-*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $New = "$Dest.new"
    Remove-Item -LiteralPath $New -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $VersionDest -Destination $New -Force
    if ((Get-FileHash -LiteralPath $New -Algorithm SHA256).Hash.ToLower() -ne $script:ExpectedHash) {
        Remove-Item -LiteralPath $New -Force -ErrorAction SilentlyContinue
        Write-Fail "The copied binary does not match the release checksum."
    }

    $Aside = $null
    try {
        if (Test-Path -LiteralPath $Dest) {
            $Aside = "$Dest.old-$(Get-Date -Format yyyyMMddHHmmss)-$PID"
            Move-WithRetry $Dest $Aside
        }
        Move-WithRetry $New $Dest
    } catch {
        if ($Aside -and -not (Test-Path -LiteralPath $Dest)) {
            Move-Item -LiteralPath $Aside -Destination $Dest -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $New -Force -ErrorAction SilentlyContinue
        Write-Fail "Could not replace $Dest ($($_.Exception.Message)). Close your coding agents and re-run the installer."
    }

    # Only now that the new binary is actually in place: a later re-run's
    # "already installed" check trusts this stamp.
    Set-Content -LiteralPath (Join-Path $InstallDir ".version") -Value $script:LatestVersion -Encoding ASCII
    Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Prune-OldVersions -JustInstalled $VersionBare
    Write-Ok "Installed to $Dest"
    Restart-DaemonTask
}

function Prune-OldVersions {
    param([string]$JustInstalled)
    # Best-effort: keep the version just installed plus the KeepVersions-1
    # most recently modified others. A stale leftover directory on failure is
    # a disk-space issue, not a correctness one — never let this interrupt
    # the install.
    $VersionsDir = Join-Path $env:USERPROFILE ".steroid\versions"
    if (-not (Test-Path $VersionsDir)) { return }
    $others = Get-ChildItem $VersionsDir -Directory -ErrorAction SilentlyContinue `
        | Where-Object { $_.Name -ne $JustInstalled } `
        | Sort-Object LastWriteTime -Descending
    $stale = $others | Select-Object -Skip ($KeepVersions - 1)
    foreach ($dir in $stale) {
        try { Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
}

# ── Write wrapper ─────────────────────────────────────────────────────────────

function Write-Wrapper {
    New-Item -ItemType Directory -Force -Path $WrapperDir | Out-Null
    $WrapperPath = Join-Path $WrapperDir "steroid.bat"
    Set-Content $WrapperPath "@echo off`r`n`"%USERPROFILE%\.steroid\bin\steroid.exe`" %*"
    Write-Ok "steroid.bat  →  $WrapperPath"
}

# ── Configure PATH ────────────────────────────────────────────────────────────

function Add-ToPath {
    $CurrentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($CurrentPath -like "*$WrapperDir*") {
        Write-Ok "$WrapperDir already in PATH"
        return
    }
    $NewPath = "$WrapperDir;$CurrentPath"
    [System.Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    Write-Ok "Added $WrapperDir to your user PATH"
    Write-Info "Restart your terminal for PATH changes to take effect."
}

# ── Install onboarding skill ────────────────────────────────────────────────────

function Install-OnboardSkill {
    # Drop the /steroid-onboard slash command into every detected coding agent.
    # The command prints which agents it wired (and the next step, or a hint if
    # none were found). Best-effort — never fail the install.
    try {
        & (Join-Path $InstallDir "steroid.exe") install-onboard-skill
    } catch {
        Write-Info "Onboarding skill step skipped ($($_.Exception.Message))"
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Header
Write-Info "Checking system requirements..."
Write-Ok "Windows detected (x86_64)"
Test-Connectivity

Write-Host ""
Get-LatestVersion

# Version guardrail (skip with -Force / $env:FORCE=1, the latter for the
# `iex (irm ...)` one-liner):
#   • already on the latest    -> say so and exit
#   • an older version present -> show installed vs available and, when
#     interactive, confirm before upgrading (default No).
$forced = $Force -or ($env:FORCE -eq '1')
$installed = Get-InstalledVersion
$want = ($script:LatestVersion -replace '^v', '')
if ((-not $forced) -and $installed) {
    if ($installed -eq $want) {
        Write-Host ""
        Write-Ok "Steroid $($script:LatestVersion) is already installed — nothing to do."
        Write-Info "Re-run with -Force (or set `$env:FORCE=1) to reinstall."
        exit 0
    }
    Write-Host ""
    Write-Info "Installed:  v$installed"
    Write-Info "Available:  $($script:LatestVersion)"
    if (-not [Console]::IsInputRedirected) {
        $ans = Read-Host "  Update v$installed -> $($script:LatestVersion)? [y/N]"
        if ($ans -notmatch '^(y|yes)$') {
            Write-Info "Keeping v$installed — nothing changed."
            exit 0
        }
    } else {
        Write-Info "Non-interactive — upgrading to $($script:LatestVersion)."
    }
}

Write-Host ""
Write-Info "Downloading Steroid $($script:LatestVersion)..."
Download-Binary

Write-Host ""
Write-Info "Installing to $InstallDir\..."
Install-Binary

Write-Host ""
Write-Info "Creating CLI command..."
Write-Wrapper

Write-Host ""
Write-Info "Configuring PATH..."
Add-ToPath

Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  [OK] Steroid $($script:LatestVersion) installed successfully!   │" -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""
Write-Info "Adding the /steroid-onboard skill to your coding agents..."
Install-OnboardSkill
Write-Host ""
Write-Host "  Steroid checks for updates once a day and updates itself, including the"
Write-Host "  skills it installed in your agents. To turn off automatic installs:"
Write-Host "  steroid update --auto off  (or Settings -> Updates in the steroid app)"
Write-Host ""
if ($env:Path -like "*$WrapperDir*") {
    Write-Info "(To use the Steroid CLI directly, just enter  steroid  — no restart needed.)"
} else {
    Write-Info "(To use the Steroid CLI directly, restart your terminal, then enter  steroid)"
}
Write-Host ""

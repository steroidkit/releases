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
    if (Test-Path $stamp) {
        return ((Get-Content $stamp -Raw).Trim() -replace '^v', '')
    }
    return $null
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
    try {
        Invoke-WebRequest "$BaseUrl/$BinaryName.sha256" -OutFile $script:TmpChecksum -UseBasicParsing
        $Expected = (Get-Content $script:TmpChecksum -Raw).Trim().Split()[0].ToLower()
        $Actual   = (Get-FileHash $script:TmpBinary -Algorithm SHA256).Hash.ToLower()
        if ($Actual -ne $Expected) {
            Write-Fail "Checksum mismatch — binary may be corrupted."
        }
        Write-Ok "Checksum verified"
    } catch {
        Write-Info "Checksum file not found, skipping verification."
    }
}

# ── Install binary ────────────────────────────────────────────────────────────

function Install-Binary {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Dest = Join-Path $InstallDir "steroid.exe"

    if (Test-Path $Dest) {
        Copy-Item $Dest (Join-Path $InstallDir "steroid.bak.exe") -Force
    }

    Copy-Item $script:TmpBinary $Dest -Force
    # Stamp the installed version so a later re-run can detect "already installed".
    Set-Content (Join-Path $InstallDir ".version") $script:LatestVersion
    Remove-Item $script:TmpDir -Recurse -Force
    Write-Ok "Installed to $Dest"
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
Write-Host "  │                                                 │" -ForegroundColor Cyan
Write-Host "  │  Restart your terminal, then run:  steroid      │" -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

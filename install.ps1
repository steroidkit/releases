# Steroid installer — Windows (PowerShell 5.1+)
# Usage: iex (irm 'https://cli.steroidkit.com/install.ps1')
#Requires -Version 5.1
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
    # blocked / rate-limited on some corporate networks. Display only; the
    # binary downloads via the latest/download redirect below. The try/catch
    # covers both PowerShell 7 (returns the 3xx response) and Windows PowerShell
    # 5.1 (throws on a 3xx when redirection is disabled).
    $loc = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://github.com/$GITHUB_RELEASES_REPO/releases/latest" `
            -Method Head -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $loc = $resp.Headers['Location']
    } catch {
        $loc = $_.Exception.Response.Headers.Location
    }
    if ($loc) { $script:LatestVersion = ([string]$loc -split '/tag/')[-1] }
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

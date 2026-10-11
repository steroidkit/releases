# Steroid installer - Windows (PowerShell 5.1+)
# Usage: iex (irm 'https://cli.steroidkit.com/install.ps1')
#Requires -Version 5.1
param([switch]$Force)

# The whole installer runs inside Install-Steroid, and only the try/catch at
# the bottom may `exit`. Under `irm ... | iex` this runs in the user's own
# PowerShell session, where `exit` would close their window, so failures
# `throw` (Write-Fail) and the early outs `return`. Being a function also
# keeps strict mode, $ErrorActionPreference and the helpers out of that
# session.
function Install-Steroid {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $GITHUB_RELEASES_REPO = "steroidkit/releases"
    $InstallDir  = Join-Path $env:USERPROFILE ".steroid\bin"
    $WrapperDir  = Join-Path $env:USERPROFILE ".local\bin"
    $BinaryName  = "steroid-windows-x86_64.exe"

    function Write-Header {
        Write-Host ""
        Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |              Steroid Installer                  |" -ForegroundColor Cyan
        Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
        Write-Host ""
    }

    function Write-Ok   { param($Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
    function Write-Info { param($Msg) Write-Host "  ... $Msg" }
    # Throw, never `exit`: the try/catch at the bottom prints "[ERR] <message>".
    function Write-Fail { param($Msg) throw $Msg }

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

    # -- Check connectivity -------------------------------------------------------

    function Test-Connectivity {
        Write-Info "Checking internet connectivity..."
        try {
            # Probe github.com (web), NOT api.github.com -- the GitHub API is blocked /
            # rate-limited on many corporate VPNs, while web + release downloads are not.
            $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -TimeoutSec 5 -UseBasicParsing
            Write-Ok "Internet reachable"
        } catch {
            Write-Fail "Cannot reach github.com. Check your network connection."
        }
    }

    # -- Fetch latest version -----------------------------------------------------

    function Get-LatestVersion {
        Write-Info "Fetching latest Steroid release..."
        # Resolve the version from the /releases/latest redirect
        # (Location: .../releases/tag/<version>) -- NOT the GitHub API, which is
        # blocked / rate-limited on some corporate networks. Every download below
        # names this exact tag, so a release going public mid-install can't mix
        # one release's binary with another's checksum.
        #
        # Use System.Net.WebRequest with redirects disabled: it behaves consistently
        # on Windows PowerShell 5.1 AND PowerShell 7. (Invoke-WebRequest
        # -MaximumRedirection 0 differs between the two -- the exception shape /
        # response-header access varies -- which under Set-StrictMode threw
        # "The property 'Response' cannot be found".) A 3xx with AllowAutoRedirect
        # disabled is returned, not thrown; the catch is a safety net for 4xx/5xx.
        #
        # Reset first: under `iex` the script scope is the user's session, so a
        # value from an earlier run in the same window would otherwise survive a
        # failed lookup (and strict mode throws on a never-set variable).
        $script:LatestVersion = $null
        $loc = $null
        try {
            # Ensure TLS 1.2 -- Windows PowerShell 5.1's raw HttpWebRequest can default
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

    # -- Choose the version to install ---------------------------------------------

    function Get-HttpStatus {
        # The HTTP status of a failed Invoke-WebRequest, or 0 when no response
        # came back (no network). Windows PowerShell 5.1 throws a WebException
        # and PowerShell 7 an HttpResponseException; both carry
        # .Response.StatusCode. Other exceptions have no .Response at all, and
        # strict mode throws on a missing property, hence the PSObject check.
        param($ErrorRecord)
        $ex = $ErrorRecord.Exception
        if ($ex.PSObject.Properties['Response'] -and $ex.Response) {
            try { return [int]$ex.Response.StatusCode } catch { }
        }
        return 0
    }

    function Get-ReleaseFile {
        # Download one asset of one exact release to $OutFile. Returns the HTTP
        # status: 200, 404 when the release lacks the file, 0 for no response.
        param([string]$Tag, [string]$Asset, [string]$OutFile)
        try {
            Invoke-WebRequest "https://github.com/$GITHUB_RELEASES_REPO/releases/download/$Tag/$Asset" -OutFile $OutFile -UseBasicParsing
            return 200
        } catch {
            return (Get-HttpStatus $_)
        }
    }

    function Get-PreviousVersion {
        # previous_version from a release-notes.json, bare (e.g. 0.4.0), or ''.
        # Only a plain X.Y.Z, so nothing else ends up in a URL or a path.
        param([string]$Path)
        try {
            $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            # Strict mode throws on a property the object doesn't have.
            if ($manifest -and $manifest.PSObject.Properties['previous_version']) {
                $prev = ([string]$manifest.previous_version) -replace '^v', ''
                if ($prev -match '^[0-9]+\.[0-9]+\.[0-9]+$') { return $prev }
            }
        } catch { }
        return ''
    }

    function Select-Version {
        # Sets $script:InstallVersion and fetches its checksum.
        #
        # The checksum comes first. A release goes public once its macOS and
        # Windows files are up, so Windows is normally there; if it isn't (a
        # halted or broken release), this installs the version the release names
        # as previous_version, which updates itself later. Never more than one
        # version back.
        #
        # The checksum is mandatory, not best-effort: every build computes one
        # alongside its binary, so a binary is never installed unverified.
        #
        # Reset first: under `iex` the script scope is the user's session.
        $script:InstallVersion = $null
        $script:TmpDir = [System.IO.Path]::GetTempPath() | Join-Path -ChildPath ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $script:TmpChecksum = Join-Path $script:TmpDir "$BinaryName.sha256"
        $latest = $script:LatestVersion

        $status = Get-ReleaseFile $latest "$BinaryName.sha256" $script:TmpChecksum
        if ($status -eq 200) { $script:InstallVersion = $latest; return }
        if ($status -ne 404) {
            Write-Fail "Could not download the checksum for $latest. Check your network connection and try again."
        }

        $notReady = "The Windows build of $latest isn't ready yet"
        $prev = ''
        $notes = Join-Path $script:TmpDir "release-notes.json"
        if ((Get-ReleaseFile $latest "release-notes.json" $notes) -eq 200) { $prev = Get-PreviousVersion $notes }
        if ((-not $prev) -or ($prev -eq ($latest -replace '^v', ''))) {
            Write-Fail "$notReady, and there's no earlier version to install instead. Try again in an hour."
        }
        $status = Get-ReleaseFile "v$prev" "$BinaryName.sha256" $script:TmpChecksum
        if ($status -eq 404) {
            Write-Fail "$notReady, and v$prev's isn't available either. Try again in an hour."
        }
        if ($status -ne 200) {
            Write-Fail "Could not download the checksum for v$prev. Check your network connection and try again."
        }
        $script:InstallVersion = "v$prev"
        Write-Info "$notReady, so installing v$prev. Steroid updates itself to $latest automatically once it is."
    }

    # -- Download + verify --------------------------------------------------------

    function Download-Binary {
        $script:TmpBinary = Join-Path $script:TmpDir $BinaryName

        Write-Info "Downloading $BinaryName..."
        Invoke-WebRequest "https://github.com/$GITHUB_RELEASES_REPO/releases/download/$($script:InstallVersion)/$BinaryName" -OutFile $script:TmpBinary -UseBasicParsing

        Write-Info "Verifying checksum..."
        $Expected = (Get-Content $script:TmpChecksum -Raw).Trim().Split()[0].ToLower()
        $Actual   = (Get-FileHash $script:TmpBinary -Algorithm SHA256).Hash.ToLower()
        if ($Actual -ne $Expected) {
            Write-Fail "Checksum mismatch -- binary may be corrupted."
        }
        $script:ExpectedHash = $Expected
        Write-Ok "Checksum verified"
    }

    # -- Install binary ------------------------------------------------------------
    #
    # Layout: a full copy of each version lives at
    # ~/.steroid/versions/<bare-ver>/steroid.exe (kept for rollback by
    # Prune-OldVersions), and Dest (~/.steroid/bin/steroid.exe) is a second,
    # independent copy of the active one. Every IDE's MCP config, the Scheduled
    # Task, and steroid.bat below all hardcode Dest as a fixed path, so it must
    # stay in place -- unlike macOS/Linux (core/binary_swap.py), Windows can't
    # repoint it at the versioned copy via a symlink without elevated privileges
    # or Developer Mode, hence the second copy rather than a move or link.
    #
    # A running steroid.exe (the daemon, any agent's `steroid mcp-server`) can't be
    # overwritten or deleted, but it CAN be renamed: the live copy is renamed
    # aside and the new one renamed into place -- the same approach steroid's own
    # updater uses (core/binary_swap.py swap_windows_in_place). Running copies
    # keep the renamed file; nothing is stopped first, so a failed swap never
    # leaves the daemon stopped. A daemon that was running is restarted
    # afterwards so it moves onto the new binary.

    $KeepVersions = 2
    $DaemonTaskName = "com.steroid.pullserver"

    function Move-WithRetry {
        param([string]$From, [string]$To)
        # Antivirus scans briefly lock freshly written executables -- retry ~2.5s.
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
            # Couldn't stop it -- still try to start below.
        } finally {
            try {
                Start-ScheduledTask -TaskName $DaemonTaskName -ErrorAction Stop
                Write-Ok "Restarted the background daemon"
            } catch {
                Write-Info "Couldn't restart the background daemon -- run 'steroid daemon start'."
            }
        }
    }

    function Install-Binary {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $Dest = Join-Path $InstallDir "steroid.exe"
        $VersionsDir = Join-Path $env:USERPROFILE ".steroid\versions"
        # Captured BEFORE creating anything below: true only the very first time
        # this versioned scheme runs on a machine that already had a (pre-scheme)
        # flat install -- used to archive that old binary instead of silently
        # discarding it.
        $IsFirstVersionedInstall = (Test-Path -LiteralPath $Dest) -and -not (Test-Path -LiteralPath $VersionsDir)

        # The version actually installed: the previous one when the Windows build
        # of the latest isn't up (Select-Version).
        $VersionBare = $script:InstallVersion -replace '^v', ''
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
        Set-Content -LiteralPath (Join-Path $InstallDir ".version") -Value $script:InstallVersion -Encoding ASCII
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Prune-OldVersions -JustInstalled $VersionBare
        Write-Ok "Installed to $Dest"
        Restart-DaemonTask
    }

    function Prune-OldVersions {
        param([string]$JustInstalled)
        # Best-effort: keep the version just installed plus the KeepVersions-1
        # most recently modified others. A stale leftover directory on failure is
        # a disk-space issue, not a correctness one -- never let this interrupt
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

    # -- Write wrapper -------------------------------------------------------------

    function Write-Wrapper {
        New-Item -ItemType Directory -Force -Path $WrapperDir | Out-Null
        $WrapperPath = Join-Path $WrapperDir "steroid.bat"
        Set-Content $WrapperPath "@echo off`r`n`"%USERPROFILE%\.steroid\bin\steroid.exe`" %*"
        Write-Ok "steroid.bat  ->  $WrapperPath"
    }

    # -- Configure PATH ------------------------------------------------------------

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

    # -- Install onboarding skill ----------------------------------------------------

    function Install-OnboardSkill {
        # Drop the /steroid-onboard slash command into every detected coding agent.
        # The command prints which agents it wired (and the next step, or a hint if
        # none were found). Best-effort -- never fail the install.
        try {
            & (Join-Path $InstallDir "steroid.exe") install-onboard-skill
        } catch {
            Write-Info "Onboarding skill step skipped ($($_.Exception.Message))"
        }
    }

    # -- Main ----------------------------------------------------------------------

    Write-Header
    Write-Info "Checking system requirements..."
    Write-Ok "Windows detected (x86_64)"
    Test-Connectivity

    Write-Host ""
    Get-LatestVersion
    Select-Version

    # Version guardrail (skip with -Force / $env:FORCE=1, the latter for the
    # `iex (irm ...)` one-liner):
    #   - already on the version to install -> say so and stop
    #   - an older version present -> show installed vs available and, when
    #     interactive, confirm before upgrading (default No).
    # $Force is the script's param, read from the enclosing scope.
    $forced = $Force -or ($env:FORCE -eq '1')
    $installed = Get-InstalledVersion
    $want = ($script:InstallVersion -replace '^v', '')
    if ((-not $forced) -and $installed) {
        if ($installed -eq $want) {
            Write-Host ""
            Write-Ok "Steroid $($script:InstallVersion) is already installed -- nothing to do."
            Write-Info "Re-run with -Force (or set `$env:FORCE=1) to reinstall."
            return
        }
        Write-Host ""
        Write-Info "Installed:  v$installed"
        Write-Info "Available:  $($script:InstallVersion)"
        if (-not [Console]::IsInputRedirected) {
            $ans = Read-Host "  Update v$installed -> $($script:InstallVersion)? [y/N]"
            if ($ans -notmatch '^(y|yes)$') {
                Write-Info "Keeping v$installed -- nothing changed."
                return
            }
        } else {
            Write-Info "Non-interactive -- upgrading to $($script:InstallVersion)."
        }
    }

    Write-Host ""
    Write-Info "Downloading Steroid $($script:InstallVersion)..."
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
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [OK] Steroid $($script:InstallVersion) installed successfully!    |" -ForegroundColor Cyan
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Adding the /steroid-onboard skill to your coding agents..."
    Install-OnboardSkill
    Write-Host ""
    Write-Host "  Steroid checks for updates once a day and updates itself, including the"
    Write-Host "  skills it installed in your agents. To turn off automatic installs:"
    Write-Host "  steroid update --auto off  (or Settings -> Updates in the steroid app)"
    Write-Host ""
    if ($env:Path -like "*$WrapperDir*") {
        Write-Info "(To use the Steroid CLI directly, just enter  steroid  -- no restart needed.)"
    } else {
        Write-Info "(To use the Steroid CLI directly, restart your terminal, then enter  steroid)"
    }
    Write-Host ""
}

# Under `irm | iex` we never call `exit`: it would close the user's window.
# $PSCommandPath is empty there, so a failure prints the error and sets
# $LASTEXITCODE for a caller in the same session. Scripted use that needs a
# real process exit code should run this as a file, where a failure exits 1:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
try { Install-Steroid } catch { Write-Host "  [ERR] $($_.Exception.Message)" -ForegroundColor Red; $global:LASTEXITCODE = 1; if ($PSCommandPath) { exit 1 } }

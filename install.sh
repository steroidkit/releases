#!/usr/bin/env sh
# Steroid installer — macOS and Linux
# Usage:  curl -fsSL https://cli.steroidkit.com/install.sh | sh
set -eu

GITHUB_RELEASES_REPO="steroidkit/releases"
INSTALL_DIR="$HOME/.steroid/bin"
WRAPPER_DIR="$HOME/.local/bin"
BINARY_NAME="steroid"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

current_version() {
    # Print the installed version bare (e.g. 0.3.0) from the stamp a previous
    # install wrote, or nothing if absent. We read a file instead of executing
    # `steroid --version` so we never run a possibly-old/broken binary (some
    # builds print nothing for --version) and there are no side effects.
    cat "$INSTALL_DIR/.version" 2>/dev/null | sed 's/^v//'
}

# ── Detect platform ───────────────────────────────────────────────────────────

detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Darwin)
            case "$ARCH" in
                arm64)  PLATFORM_BINARY="steroid-macos-arm64" ;;
                # Intel Macs: no native x86_64 binary — arm64 runs via Rosetta 2
                x86_64) PLATFORM_BINARY="steroid-macos-arm64" ;;
                *)      die "Unsupported macOS architecture: $ARCH" ;;
            esac
            ;;
        Linux)
            case "$ARCH" in
                x86_64)          PLATFORM_BINARY="steroid-linux-x86_64" ;;
                aarch64 | arm64) PLATFORM_BINARY="steroid-linux-arm64"  ;;
                *)               die "Unsupported Linux architecture: $ARCH" ;;
            esac
            ;;
        *)
            die "Unsupported OS: $OS. Use install.ps1 on Windows."
            ;;
    esac
}

# ── Check internet ────────────────────────────────────────────────────────────

check_connectivity() {
    # Probe github.com (web), NOT api.github.com — the GitHub API is blocked /
    # rate-limited on many corporate VPNs, while web + release downloads are not.
    if curl -fsSL --connect-timeout 5 -o /dev/null "https://github.com"; then
        ok "Internet reachable"
    else
        die "Cannot reach github.com. Check your network connection."
    fi
}

# ── Fetch latest version ──────────────────────────────────────────────────────

fetch_latest_version() {
    # Resolve the version from the /releases/latest redirect
    # (Location: .../releases/tag/<version>) — NOT the GitHub API, which is
    # blocked / rate-limited on some corporate networks. Display only; the
    # binary downloads via the latest/download redirect in download_binary().
    _redirect="$(
        curl -fsS -o /dev/null -w '%{redirect_url}' \
            "https://github.com/${GITHUB_RELEASES_REPO}/releases/latest"
    )"
    LATEST_VERSION="${_redirect##*/tag/}"
    { [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$_redirect" ]; } \
        || die "Could not determine latest version."
    ok "Latest version: $LATEST_VERSION"
}

# ── Download + verify ─────────────────────────────────────────────────────────

download_binary() {
    # latest/download resolves the newest release server-side — no API, no
    # version pinning needed in the URL.
    BASE_URL="https://github.com/${GITHUB_RELEASES_REPO}/releases/latest/download"
    TMP_DIR="$(mktemp -d)"
    TMP_BINARY="$TMP_DIR/$PLATFORM_BINARY"
    TMP_CHECKSUM="$TMP_DIR/${PLATFORM_BINARY}.sha256"

    log "Downloading $PLATFORM_BINARY..."
    curl -fSL --progress-bar \
        "$BASE_URL/$PLATFORM_BINARY" \
        -o "$TMP_BINARY" \
        || die "Download failed."

    log "Verifying checksum..."
    # Mandatory, not best-effort: every build (CI for Linux, scripts/build-local.sh
    # / .ps1 for macOS/Windows) computes a .sha256 alongside its binary, so a
    # missing one means the release upload step was incomplete, not that no
    # checksum was ever produced — worth aborting over, not silently installing
    # an unverified binary.
    curl -fsSL "$BASE_URL/${PLATFORM_BINARY}.sha256" -o "$TMP_CHECKSUM" \
        || die "No checksum published for this release — refusing to install an unverified binary."
    EXPECTED="$(awk '{print $1}' "$TMP_CHECKSUM")"
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL="$(sha256sum "$TMP_BINARY" | awk '{print $1}')"
    else
        ACTUAL="$(shasum -a 256 "$TMP_BINARY" | awk '{print $1}')"
    fi
    [ "$ACTUAL" = "$EXPECTED" ] || die "Checksum mismatch — binary may be corrupted."
    ok "Checksum verified"
}

# ── Install binary ────────────────────────────────────────────────────────────
#
# Layout: real binaries live under ~/.steroid/versions/<bare-ver>/steroid; DEST
# (~/.steroid/bin/steroid) is a symlink to the active one, flipped by a
# same-directory `mv` — POSIX guarantees that's an atomic rename, safe even if
# DEST is the very file a running `steroid` process currently has open (the
# kernel keeps that process's data alive regardless of what the directory
# entry points to next). This mirrors steroid_client's core/binary_swap.py —
# used by `steroid update` — so the two agree on the same on-disk shape and a
# machine never ends up with a mix of swap styles.
#
# Every IDE's MCP config, the launchd plist/systemd unit, and the wrapper
# below all hardcode DEST as a fixed path — that's exactly why it must stay a
# stable symlink rather than move to a version-specific path.

KEEP_VERSIONS=2

install_binary() {
    DEST="$INSTALL_DIR/$BINARY_NAME"
    VERSIONS_DIR="$HOME/.steroid/versions"
    VERSION_BARE="${LATEST_VERSION#v}"
    VERSION_DEST="$VERSIONS_DIR/$VERSION_BARE/$BINARY_NAME"

    mkdir -p "$INSTALL_DIR" "$(dirname "$VERSION_DEST")"
    # Stage under a temp name, then rename — never `cp` onto VERSION_DEST.
    # On a forced reinstall of the version that's already live, VERSION_DEST
    # is the file running steroid processes (the daemon, agent MCP servers)
    # are executing; overwriting it in place can get them killed on macOS.
    # A rename gives the new copy its own inode and leaves running ones alone.
    STAGE_TMP="$VERSION_DEST.tmp.$$"
    cp -f "$TMP_BINARY" "$STAGE_TMP"
    chmod +x "$STAGE_TMP"
    mv -f "$STAGE_TMP" "$VERSION_DEST"
    # Same checksum sidecar steroid's own updater writes (core/binary_swap.py),
    # so it recognises this exact build as already staged.
    printf '%s\n' "$EXPECTED" > "$(dirname "$VERSION_DEST")/.sha256"

    # An install from before versioned directories existed has a plain file
    # (not a symlink) at DEST. Preserve it under a synthetic "legacy" slot
    # rather than silently discarding it, then proceed with the normal swap.
    if [ -f "$DEST" ] && [ ! -L "$DEST" ]; then
        mkdir -p "$VERSIONS_DIR/legacy"
        cp -f "$DEST" "$VERSIONS_DIR/legacy/$BINARY_NAME" 2>/dev/null || true
    fi

    # Atomic swap: point a temp symlink at the new version, then rename it
    # over DEST. Same directory → same filesystem → the rename is atomic and
    # there is no moment where DEST is missing or truncated.
    ln -sf "$VERSION_DEST" "$INSTALL_DIR/.steroid.new"
    mv -f "$INSTALL_DIR/.steroid.new" "$DEST"

    # Stamp the installed version so a later re-run can detect "already installed".
    printf '%s\n' "$LATEST_VERSION" > "$INSTALL_DIR/.version"
    rm -rf "$TMP_DIR"
    prune_old_versions "$VERSION_BARE"
    ok "Installed to $DEST"
    restart_daemon
}

restart_daemon() {
    # A running background daemon keeps executing the binary it started with
    # until it restarts. On an upgrade, bounce it now so it runs the new
    # version (and applies the update's migrations) immediately. Only touches
    # a daemon that's already registered — a fresh install's daemon is
    # registered later, by the TUI or `steroid setup`. Never fails the install.
    case "$OS" in
        Darwin)
            if launchctl kickstart -k "gui/$(id -u)/com.steroid.pullserver" >/dev/null 2>&1; then
                ok "Restarted the background daemon"
            fi
            ;;
        Linux)
            if command -v systemctl >/dev/null 2>&1 \
                && systemctl --user is-active --quiet steroid.service 2>/dev/null; then
                systemctl --user restart steroid.service >/dev/null 2>&1 \
                    && ok "Restarted the background daemon"
            fi
            ;;
    esac
    return 0
}

prune_old_versions() {
    # Best-effort: keep the version just installed ($1) plus the
    # KEEP_VERSIONS-1 most recently modified others, so a bad release has a
    # same-day rollback target without old versions accumulating forever. A
    # stale leftover directory on failure is a disk-space issue, not a
    # correctness one — never let this interrupt the install.
    _just_installed="$1"
    VERSIONS_DIR="$HOME/.steroid/versions"
    [ -d "$VERSIONS_DIR" ] || return 0
    ls -1t "$VERSIONS_DIR" 2>/dev/null \
        | grep -vxF "$_just_installed" \
        | tail -n "+$KEEP_VERSIONS" \
        | while IFS= read -r stale; do
            rm -rf "${VERSIONS_DIR:?}/${stale:?}" 2>/dev/null || true
        done
}

# ── Write wrapper ─────────────────────────────────────────────────────────────

write_wrapper() {
    mkdir -p "$WRAPPER_DIR"
    WRAPPER="$WRAPPER_DIR/$BINARY_NAME"
    cat > "$WRAPPER" <<EOF
#!/bin/sh
exec "\$HOME/.steroid/bin/steroid" "\$@"
EOF
    chmod +x "$WRAPPER"
    ok "steroid  →  $WRAPPER"
}

# ── Configure PATH ────────────────────────────────────────────────────────────

configure_path() {
    PATH_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
    CONFIGURED=0

    case "$SHELL" in
        */zsh)
            PROFILE="$HOME/.zshrc"
            ;;
        */fish)
            # fish uses a different syntax; just print instructions
            ok "Add ~/.local/bin to your fish PATH manually: set -U fish_user_paths ~/.local/bin \$fish_user_paths"
            return
            ;;
        *)
            PROFILE="$HOME/.bashrc"
            [ -f "$HOME/.bash_profile" ] && PROFILE="$HOME/.bash_profile"
            ;;
    esac

    if echo "$PATH" | grep -q "$WRAPPER_DIR"; then
        ok "~/.local/bin already in PATH"
        return
    fi

    if grep -qF "$WRAPPER_DIR" "$PROFILE" 2>/dev/null; then
        ok "~/.local/bin already configured in $PROFILE"
        return
    fi

    printf '\n# Added by Steroid installer\n%s\n' "$PATH_LINE" >> "$PROFILE"
    ok "Added ~/.local/bin to $PROFILE"
    CONFIGURED=1
}

# ── Install onboarding skill ────────────────────────────────────────────────────

install_onboard_skill() {
    # Drop the /steroid-onboard slash command into every detected coding agent.
    # We let the command's own output through (instead of a generic line) so the
    # user sees exactly which agents got the skill — and the next step, or a hint
    # if none were found. Best-effort — never fail the install.
    "$INSTALL_DIR/$BINARY_NAME" install-onboard-skill || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Force reinstall via `FORCE=1` env or a --force/-f arg (works with the
    # `curl … | sh` pipe as `curl … | FORCE=1 sh`, or `sh -s -- --force`).
    FORCE="${FORCE:-0}"
    for _arg in "$@"; do
        case "$_arg" in
            --force|-f) FORCE=1 ;;
        esac
    done

    printf '\n  \033[1m┌─────────────────────────────────────────────────┐\033[0m\n'
    printf   '  \033[1m│              Steroid Installer                  │\033[0m\n'
    printf   '  \033[1m└─────────────────────────────────────────────────┘\033[0m\n\n'

    log "Checking system requirements..."
    need curl
    detect_platform
    ok "$OS $ARCH detected"
    check_connectivity

    printf '\n'
    log "Fetching latest Steroid release..."
    fetch_latest_version

    # Version guardrail (skip entirely with FORCE=1 / --force):
    #   • already on the latest    → say so and exit
    #   • an older version present → show installed vs available and, when a
    #     terminal is attached, confirm before upgrading (default No). Piped
    #     `curl | sh` means stdin is the script, so we read the answer from
    #     /dev/tty; with no tty (CI) we upgrade automatically.
    INSTALLED_VERSION="$(current_version)"
    if [ "$FORCE" != "1" ] && [ -n "$INSTALLED_VERSION" ]; then
        if [ "$INSTALLED_VERSION" = "${LATEST_VERSION#v}" ]; then
            printf '\n'
            ok "Steroid $LATEST_VERSION is already installed — nothing to do."
            log "Re-run with FORCE=1 (or --force) to reinstall."
            exit 0
        fi
        printf '\n'
        log "Installed:  v$INSTALLED_VERSION"
        log "Available:  $LATEST_VERSION"
        if [ -r /dev/tty ]; then
            printf '  Update v%s → %s? [y/N] ' "$INSTALLED_VERSION" "$LATEST_VERSION"
            read _ans < /dev/tty || _ans=""
            case "$_ans" in
                y|Y|yes|YES) ;;
                *) log "Keeping v$INSTALLED_VERSION — nothing changed."; exit 0 ;;
            esac
        else
            log "Non-interactive — upgrading to $LATEST_VERSION."
        fi
    fi

    printf '\n'
    log "Downloading Steroid $LATEST_VERSION..."
    download_binary

    printf '\n'
    log "Installing to $INSTALL_DIR/..."
    install_binary

    printf '\n'
    log "Creating CLI command..."
    write_wrapper

    printf '\n'
    log "Configuring PATH..."
    configure_path

    printf '\n'
    printf '  \033[1m┌─────────────────────────────────────────────────┐\033[0m\n'
    printf   "  \033[1m│  \033[32m✓\033[0m  Steroid $LATEST_VERSION installed successfully!     \033[1m│\033[0m\n"
    printf   '  \033[1m└─────────────────────────────────────────────────┘\033[0m\n\n'
    log "Adding the /steroid-onboard skill to your coding agents..."
    install_onboard_skill

    printf '\n'
    printf '  Steroid checks for updates once a day and updates itself, including the\n'
    printf '  skills it installed in your agents. To turn off automatic installs:\n'
    printf '  steroid update --auto off  (or Settings → Updates in the steroid app)\n'

    printf '\n'
    if echo "$PATH" | grep -q "$WRAPPER_DIR"; then
        printf '  (To use the Steroid CLI directly, just enter  steroid  — no restart needed.)\n\n'
    else
        printf '  (To use the Steroid CLI directly, restart your terminal, then enter  steroid)\n\n'
    fi
}

main "$@"

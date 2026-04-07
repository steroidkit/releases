#!/usr/bin/env sh
# Steroid installer — macOS and Linux
# Usage:  curl -fsSL https://raw.githubusercontent.com/steroidkit/releases/main/install.sh | sh
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
    if curl -fsSL --connect-timeout 5 "https://api.github.com" >/dev/null 2>&1; then
        ok "Internet reachable"
    else
        die "Cannot reach github.com. Check your network connection."
    fi
}

# ── Fetch latest version ──────────────────────────────────────────────────────

fetch_latest_version() {
    LATEST_VERSION="$(
        curl -fsSL "https://api.github.com/repos/${GITHUB_RELEASES_REPO}/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
    )"
    [ -n "$LATEST_VERSION" ] || die "Could not determine latest version."
    ok "Latest version: $LATEST_VERSION"
}

# ── Download + verify ─────────────────────────────────────────────────────────

download_binary() {
    BASE_URL="https://github.com/${GITHUB_RELEASES_REPO}/releases/download/${LATEST_VERSION}"
    TMP_DIR="$(mktemp -d)"
    TMP_BINARY="$TMP_DIR/$PLATFORM_BINARY"
    TMP_CHECKSUM="$TMP_DIR/${PLATFORM_BINARY}.sha256"

    log "Downloading $PLATFORM_BINARY..."
    curl -fSL --progress-bar \
        "$BASE_URL/$PLATFORM_BINARY" \
        -o "$TMP_BINARY" \
        || die "Download failed."

    log "Verifying checksum..."
    if curl -fsSL "$BASE_URL/${PLATFORM_BINARY}.sha256" -o "$TMP_CHECKSUM" 2>/dev/null; then
        EXPECTED="$(awk '{print $1}' "$TMP_CHECKSUM")"
        if command -v sha256sum >/dev/null 2>&1; then
            ACTUAL="$(sha256sum "$TMP_BINARY" | awk '{print $1}')"
        else
            ACTUAL="$(shasum -a 256 "$TMP_BINARY" | awk '{print $1}')"
        fi
        [ "$ACTUAL" = "$EXPECTED" ] || die "Checksum mismatch — binary may be corrupted."
        ok "Checksum verified"
    else
        log "Checksum file not found, skipping verification."
    fi
}

# ── Install binary ────────────────────────────────────────────────────────────

install_binary() {
    mkdir -p "$INSTALL_DIR"
    DEST="$INSTALL_DIR/$BINARY_NAME"

    if [ -f "$DEST" ]; then
        cp -f "$DEST" "${DEST}.bak" 2>/dev/null || true
    fi

    cp -f "$TMP_BINARY" "$DEST"
    chmod +x "$DEST"
    rm -rf "$TMP_DIR"
    ok "Installed to $DEST"
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

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
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
    printf   '  \033[1m│                                                 │\033[0m\n'
    printf   '  \033[1m│  Restart your terminal, then run:  steroid      │\033[0m\n'
    printf   '  \033[1m└─────────────────────────────────────────────────┘\033[0m\n\n'
}

main "$@"

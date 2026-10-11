#!/bin/sh
# Tests install.sh's version choice, downloads and fallback with `curl`
# replaced by a shell function that serves a fake steroidkit/releases from a
# directory. Sources install.sh with STEROID_INSTALL_SOURCE_ONLY=1. HOME is a
# temp dir and PATH holds only a few core tools plus a `uname` stub (no real
# curl, launchctl or systemctl), so nothing reaches the network, the real
# HOME or a real daemon.
#
# Usage:  sh tests/test_download.sh
#         TEST_SH=dash sh tests/test_download.sh   # source under another shell
# Exits non-zero if any case fails.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install.sh"
TEST_SH="${TEST_SH:-sh}"
TEST_SH_PATH="$(command -v "$TEST_SH")" || { echo "shell not found: $TEST_SH" >&2; exit 2; }

REPO_URL="https://github.com/steroidkit/releases"
LINUX_X64="steroid-linux-x86_64"
MAC="steroid-macos-arm64"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
TOOLS="$WORK/tools"     # the only PATH the sourced installer sees
SERVER="$WORK/server"   # $SERVER/<tag>/<asset> is releases/download/<tag>/<asset>
CURL_LOG="$WORK/curl.log"
mkdir -p "$TOOLS"
for _tool in awk cat chmod cp dirname grep head ln ls mkdir mktemp mv rm sed sha256sum shasum tail; do
    _path="$(command -v "$_tool" 2>/dev/null)" && ln -s "$_path" "$TOOLS/$_tool"
done
cat > "$TOOLS/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo x86_64 ;;
    *)  echo "uname stub: unexpected args: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TOOLS/uname"

# The curl stand-in, sourced after install.sh (a function wins over PATH).
# Understands what install.sh passes: -o, -w '%{http_code}' / '%{redirect_url}',
# -f in a short-option cluster, --connect-timeout N. Every URL goes to
# $CURL_LOG. $FAKE_LATEST is the tag /releases/latest redirects to, and
# $FAKE_FAIL_URL a URL that fails like a dropped network.
cat > "$WORK/stub_curl.sh" <<'EOF'
curl() {
    _c_out=""; _c_fmt=""; _c_url=""; _c_fail=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) _c_out="$2"; shift ;;
            -w) _c_fmt="$2"; shift ;;
            --connect-timeout) shift ;;
            --*) ;;
            -*) case "$1" in *f*) _c_fail=1 ;; esac ;;
            *)  _c_url="$1" ;;
        esac
        shift
    done
    printf '%s\n' "$_c_url" >> "$CURL_LOG"
    _c_base="https://github.com/steroidkit/releases"
    if [ "$_c_url" = "${FAKE_FAIL_URL:-}" ]; then
        case "$_c_fmt" in *http_code*) printf '000' ;; esac
        echo "curl: (6) Could not resolve host: github.com" >&2
        return 6
    fi
    _c_code=404; _c_src=""; _c_redirect=""
    case "$_c_url" in
        https://github.com) _c_code=200 ;;
        "$_c_base/releases/latest")
            if [ -n "$FAKE_LATEST" ]; then _c_code=302; _c_redirect="$_c_base/releases/tag/$FAKE_LATEST"; fi ;;
        "$_c_base/releases/download/"*)
            _c_src="$FAKE_SERVER/${_c_url#"$_c_base/releases/download/"}"
            [ -f "$_c_src" ] && _c_code=200 ;;
    esac
    if [ "$_c_code" = 200 ] && [ -n "$_c_src" ]; then
        if [ -n "$_c_out" ]; then cat "$_c_src" > "$_c_out"; else cat "$_c_src"; fi
    elif [ "$_c_code" = 404 ] && [ "$_c_fail" = 0 ] && [ -n "$_c_out" ]; then
        printf 'Not Found' > "$_c_out"
    fi
    case "$_c_fmt" in
        *http_code*)    printf '%s' "$_c_code" ;;
        *redirect_url*) printf '%s' "$_c_redirect" ;;
    esac
    if [ "$_c_code" = 404 ] && [ "$_c_fail" = 1 ]; then
        echo "curl: (22) The requested URL returned error: 404" >&2
        return 22
    fi
    return 0
}
EOF

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# publish <tag> <binary>...: put each binary and its matching .sha256 on the fake release.
publish() {
    _tag="$1"; shift
    mkdir -p "$SERVER/$_tag"
    for _bin in "$@"; do
        printf '#!/bin/sh\necho "fake steroid %s $*"\n' "$_tag" > "$SERVER/$_tag/$_bin"
        printf '%s  %s\n' "$(sha256_of "$SERVER/$_tag/$_bin")" "$_bin" > "$SERVER/$_tag/$_bin.sha256"
    done
}

# manifest <tag> [<previous_version>]: release-notes.json exactly as
# scripts/publish_release.py writes it (build_manifest: json.dumps indent=2,
# previous_version last when it's known).
manifest() {
    mkdir -p "$SERVER/$1"
    {
        printf '{\n  "version": "%s",\n  "date": "2026-10-12",\n  "headline": null,\n' "${1#v}"
        printf '  "bullets": [\n    "Something new: \\"previous_version\\": \\"0.0.1\\" is not a key."\n  ],\n'
        printf '  "security": false,\n  "requires_reconnect": false,\n  "migrations": [],\n'
        printf '  "audience": "all",\n  "published_at": "2026-10-12T12:00:00Z"'
        if [ $# -gt 1 ]; then printf ',\n  "previous_version": "%s"' "$2"; fi
        printf '\n}\n'
    } > "$SERVER/$1/release-notes.json"
}

reset() {
    rm -rf "$SERVER" "$WORK/home"
    mkdir -p "$SERVER" "$WORK/home"
    FAKE_LATEST=v0.4.4
    FAKE_FAIL_URL=""
}

# run <commands>: a fresh shell that sources install.sh and the curl stub,
# with restart_daemon stubbed too, then runs <commands>.
run() {
    : > "$CURL_LOG"
    env -i PATH="$TOOLS" HOME="$WORK/home" SHELL=/bin/sh \
        FAKE_SERVER="$SERVER" FAKE_LATEST="$FAKE_LATEST" FAKE_FAIL_URL="$FAKE_FAIL_URL" CURL_LOG="$CURL_LOG" \
        STEROID_INSTALL_SOURCE_ONLY=1 INSTALL_SH="$INSTALL_SH" STUB_CURL="$WORK/stub_curl.sh" \
        "$TEST_SH_PATH" -c '. "$INSTALL_SH"; . "$STUB_CURL"
            restart_daemon() { echo "restart_daemon stubbed"; }
            '"$1" > "$WORK/out" 2> "$WORK/err"
    STATUS=$?
}

# What tests call after sourcing: pick a platform, then the download steps.
CHOOSE='PLATFORM_BINARY="$BIN"; OS=Linux
    fetch_latest_version; choose_version; download_binary
    printf "INSTALL=%s\n" "$INSTALL_VERSION"'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$1" "$2"
    printf '      status=%s\n      stdout: %s\n      stderr: %s\n      curl: %s\n' \
        "$STATUS" "$(cat "$WORK/out")" "$(cat "$WORK/err")" "$(tr '\n' ' ' < "$CURL_LOG")"
}
out_has() { grep -qF -- "$1" "$WORK/out"; }
err_has() { grep -qF -- "$1" "$WORK/err"; }
fetched() { grep -qxF -- "$1" "$CURL_LOG"; }
line_of() { grep -nxF -- "$1" "$CURL_LOG" | head -n 1 | cut -d: -f1; }
dl() { printf '%s/releases/download/%s/%s' "$REPO_URL" "$1" "$2"; }

echo "downloads (install.sh sourced under $TEST_SH_PATH, curl stubbed)"

# ── Exact-tag URLs ────────────────────────────────────────────────────────────
reset
publish v0.4.4 "$LINUX_X64"
run "BIN=$LINUX_X64; $CHOOSE"
name="the latest release is downloaded by its exact tag, checksum first"
if [ "$STATUS" -ne 0 ]; then fail "$name" "expected success"
elif ! out_has "INSTALL=v0.4.4"; then fail "$name" "expected v0.4.4"
elif ! out_has "Checksum verified"; then fail "$name" "checksum not verified"
elif ! fetched "$(dl v0.4.4 "$LINUX_X64.sha256")" || ! fetched "$(dl v0.4.4 "$LINUX_X64")"; then
    fail "$name" "expected releases/download/v0.4.4/ URLs"
elif [ "$(line_of "$(dl v0.4.4 "$LINUX_X64.sha256")")" -ge "$(line_of "$(dl v0.4.4 "$LINUX_X64")")" ]; then
    fail "$name" "the binary was fetched before its checksum"
elif grep -q 'latest/download' "$CURL_LOG"; then fail "$name" "used releases/latest/download"
elif grep -q 'release-notes.json' "$CURL_LOG"; then fail "$name" "fetched the manifest without needing a fallback"
else pass "$name"; fi

# ── Checksum 404: the previous version ───────────────────────────────────────
reset
publish v0.4.4 "$MAC"
manifest v0.4.4 0.4.3
publish v0.4.3 "$LINUX_X64" "$MAC"
run "BIN=$LINUX_X64; $CHOOSE"
name="Linux not on the release yet: installs previous_version"
msg="The Linux build of v0.4.4 isn't ready yet, so installing v0.4.3. Steroid updates itself to v0.4.4 automatically once it is."
if [ "$STATUS" -ne 0 ]; then fail "$name" "expected success"
elif ! out_has "INSTALL=v0.4.3"; then fail "$name" "expected v0.4.3"
elif ! out_has "$msg"; then fail "$name" "expected: $msg"
elif ! out_has "Checksum verified"; then fail "$name" "checksum not verified"
elif ! fetched "$(dl v0.4.4 release-notes.json)"; then fail "$name" "didn't read v0.4.4's manifest"
elif ! fetched "$(dl v0.4.3 "$LINUX_X64")" || fetched "$(dl v0.4.4 "$LINUX_X64")"; then
    fail "$name" "expected the binary from v0.4.3 only"
elif [ "$(line_of "$(dl v0.4.3 "$LINUX_X64.sha256")")" -ge "$(line_of "$(dl v0.4.3 "$LINUX_X64")")" ]; then
    fail "$name" "the binary was fetched before its checksum"
else pass "$name"; fi

# Worded for the platform: the same on a Mac whose build isn't up.
reset
publish v0.4.4 "$LINUX_X64"
manifest v0.4.4 0.4.3
publish v0.4.3 "$MAC"
run "BIN=$MAC; $CHOOSE"
name="the fallback message names the platform (macOS)"
if [ "$STATUS" -eq 0 ] && out_has "INSTALL=v0.4.3" \
    && out_has "The macOS build of v0.4.4 isn't ready yet, so installing v0.4.3."; then pass "$name"
else fail "$name" "expected the macOS wording and v0.4.3"; fi

# The whole install: versions/<ver>, bin/.version and the success line name
# the version actually installed.
reset
publish v0.4.4 "$MAC"
manifest v0.4.4 0.4.3
publish v0.4.3 "$LINUX_X64"
run 'main'
name="main installs and records the fallback version"
link="$(ls -l "$WORK/home/.steroid/bin/steroid" 2>/dev/null)"
if [ "$STATUS" -ne 0 ]; then fail "$name" "expected success"
elif [ "$(cat "$WORK/home/.steroid/bin/.version" 2>/dev/null)" != "v0.4.3" ]; then fail "$name" "bin/.version isn't v0.4.3"
elif [ ! -x "$WORK/home/.steroid/versions/0.4.3/steroid" ] || [ -e "$WORK/home/.steroid/versions/0.4.4" ]; then
    fail "$name" "expected versions/0.4.3 only"
elif [ "${link%"$WORK/home/.steroid/versions/0.4.3/steroid"}" = "$link" ]; then fail "$name" "bin/steroid doesn't link to versions/0.4.3"
elif ! out_has "Steroid v0.4.3 installed successfully"; then fail "$name" "success line doesn't name v0.4.3"
elif ! out_has "fake steroid v0.4.3 install-onboard-skill"; then fail "$name" "onboard-skill step didn't run the installed binary"
elif ! out_has "Steroid checks for updates once a day"; then fail "$name" "update disclosure missing"
else pass "$name"; fi

# A re-run while Linux is still missing: already on the fallback version.
run 'main'
name="re-run during the Linux window: already installed"
if [ "$STATUS" -eq 0 ] && out_has "Steroid v0.4.3 is already installed — nothing to do." \
    && ! fetched "$(dl v0.4.3 "$LINUX_X64")"; then pass "$name"
else fail "$name" "expected 'already installed' and no download"; fi

# Linux lands: the same installer now installs the latest.
publish v0.4.4 "$LINUX_X64"
run 'FORCE=1 main'
name="once Linux lands, the latest installs"
if [ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/home/.steroid/bin/.version")" = "v0.4.4" ] \
    && [ -x "$WORK/home/.steroid/versions/0.4.4/steroid" ] && ! out_has "isn't ready yet"; then pass "$name"
else fail "$name" "expected v0.4.4 installed"; fi

# ── Never more than one version back: clear failures ────────────────────────
# expect_try_later <name> <message>
expect_try_later() {
    if [ "$STATUS" -ne 1 ]; then fail "$1" "expected exit 1"
    elif ! err_has "$2"; then fail "$1" "expected: $2"
    elif out_has "INSTALL="; then fail "$1" "a version was chosen"
    elif grep -q "/$LINUX_X64\$" "$CURL_LOG"; then fail "$1" "a binary was downloaded"
    else pass "$1"; fi
}
NOT_READY="The Linux build of v0.4.4 isn't ready yet"

reset
publish v0.4.4 "$MAC"
manifest v0.4.4
publish v0.4.3 "$LINUX_X64"
run "BIN=$LINUX_X64; $CHOOSE"
expect_try_later "manifest without previous_version" \
    "$NOT_READY, and there's no earlier version to install instead. Try again in an hour."

reset
publish v0.4.4 "$MAC"
publish v0.4.3 "$LINUX_X64"
run "BIN=$LINUX_X64; $CHOOSE"
expect_try_later "release without a manifest" \
    "$NOT_READY, and there's no earlier version to install instead. Try again in an hour."

reset
publish v0.4.4 "$MAC"
manifest v0.4.4 0.4.3
publish v0.4.3 "$MAC"
run "BIN=$LINUX_X64; $CHOOSE"
expect_try_later "previous version lacks this platform too (never two back)" \
    "$NOT_READY, and v0.4.3's isn't available either. Try again in an hour."
if grep -qE '/v0\.4\.[12]/' "$CURL_LOG" || [ "$(grep -c 'release-notes.json' "$CURL_LOG")" -ne 1 ]; then
    fail "only the latest release's manifest is read" "went further back"
else pass "only the latest release's manifest is read"; fi

reset
publish v0.4.4 "$MAC"
manifest v0.4.4 0.4.4
run "BIN=$LINUX_X64; $CHOOSE"
expect_try_later "previous_version naming the release itself" \
    "$NOT_READY, and there's no earlier version to install instead. Try again in an hour."

reset
publish v0.4.4 "$LINUX_X64"
FAKE_FAIL_URL="$(dl v0.4.4 "$LINUX_X64.sha256")"
run "BIN=$LINUX_X64; $CHOOSE"
name="a network failure is not a 404: no fallback"
if [ "$STATUS" -eq 1 ] && err_has "Could not download the checksum for v0.4.4. Check your network connection" \
    && ! grep -q 'release-notes.json' "$CURL_LOG"; then pass "$name"
else fail "$name" "expected a network error and no fallback"; fi

reset
publish v0.4.4 "$LINUX_X64"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$LINUX_X64" \
    > "$SERVER/v0.4.4/$LINUX_X64.sha256"
run "BIN=$LINUX_X64; $CHOOSE"
name="a checksum mismatch still refuses"
if [ "$STATUS" -eq 1 ] && err_has "Checksum mismatch"; then pass "$name"
else fail "$name" "expected the mismatch refusal"; fi

# ── previous_version parsing (sed, no jq) ────────────────────────────────────
echo "previous_version_of"

# expect_prev <name> <expected> <file content>
expect_prev() {
    printf '%s\n' "$3" > "$WORK/notes.json"
    run 'printf "PREV=[%s]\n" "$(previous_version_of "$HOME/../notes.json")"'
    if [ "$STATUS" -eq 0 ] && out_has "PREV=[$2]"; then pass "$1"
    else fail "$1" "expected [$2]"; fi
}

reset
manifest v0.4.4 0.4.3
cp "$SERVER/v0.4.4/release-notes.json" "$WORK/notes.json"
run 'printf "PREV=[%s]\n" "$(previous_version_of "$HOME/../notes.json")"'
if [ "$STATUS" -eq 0 ] && out_has "PREV=[0.4.3]"; then pass "publish_release.py's format (indent=2, last key)"
else fail "publish_release.py's format (indent=2, last key)" "expected [0.4.3]"; fi

expect_prev "not the last key (trailing comma)" "0.4.3" '{
  "previous_version": "0.4.3",
  "version": "0.4.4"
}'
expect_prev "a leading v is dropped" "0.4.3" '  "previous_version": "v0.4.3"'
expect_prev "multi-digit parts" "10.20.300" '  "previous_version": "10.20.300"'
expect_prev "compact JSON on one line" "0.4.3" '{"version": "0.4.4", "previous_version": "0.4.3"}'
expect_prev "missing" "" '{
  "version": "0.4.4"
}'
expect_prev "null" "" '  "previous_version": null'
expect_prev "a pre-release isn't a plain version" "" '  "previous_version": "0.4.3-rc.1"'
expect_prev "four parts isn't a plain version" "" '  "previous_version": "0.4.3.1"'
expect_prev "a path can't sneak into a URL" "" '  "previous_version": "0.4.3/../../evil"'
expect_prev "another key ending in previous_version" "" '  "not_previous_version": "0.4.3"'
expect_prev "quoted inside a note" "" '  "bullets": ["\"previous_version\": \"0.0.1\""]'

echo "install.sh structure"
if grep -n 'latest/download' "$INSTALL_SH" > "$WORK/out"; then
    STATUS=1; : > "$WORK/err"; : > "$CURL_LOG"; fail "no releases/latest/download URL" "found: $(cat "$WORK/out")"
else pass "no releases/latest/download URL"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

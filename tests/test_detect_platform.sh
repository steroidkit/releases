#!/bin/sh
# Tests install.sh's detect_platform with `uname` and `sysctl` stubbed on PATH.
# Sources install.sh with STEROID_INSTALL_SOURCE_ONLY=1, so nothing is
# downloaded or installed and the real HOME is never touched.
#
# Usage:  sh tests/test_detect_platform.sh
#         TEST_SH=dash sh tests/test_detect_platform.sh   # source under another shell
# Exits non-zero if any case fails.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install.sh"
TEST_SH="${TEST_SH:-sh}"
TEST_SH_PATH="$(command -v "$TEST_SH")" || { echo "shell not found: $TEST_SH" >&2; exit 2; }

INTEL_MSG="Steroid supports Apple Silicon Macs (M1 or later) only — Intel Macs aren't supported."
ROSETTA_NOTE="Apple Silicon Mac detected (shell running under Rosetta) — installing the arm64 build."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
STUBS="$WORK/stubs"         # uname + sysctl
NO_SYSCTL="$WORK/no-sysctl" # uname only: sysctl missing from PATH
mkdir -p "$STUBS" "$NO_SYSCTL" "$WORK/home"

cat > "$STUBS/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) printf '%s\n' "$STUB_OS" ;;
    -m) printf '%s\n' "$STUB_ARCH" ;;
    *)  echo "uname stub: unexpected args: $*" >&2; exit 2 ;;
esac
EOF
# STUB_SYSCTL: a value to print, "fail" (an Intel Mac: the key doesn't exist),
# or "1-then-fail" (prints 1 but exits non-zero).
cat > "$STUBS/sysctl" <<'EOF'
#!/bin/sh
echo called >> "$STUB_CALLS"
[ "$*" = "-n hw.optional.arm64" ] || { echo "sysctl stub: unexpected args: $*" >&2; exit 2; }
case "$STUB_SYSCTL" in
    fail)        echo "sysctl: unknown oid 'hw.optional.arm64'" >&2; exit 1 ;;
    1-then-fail) echo 1; exit 1 ;;
    *)           printf '%s\n' "$STUB_SYSCTL" ;;
esac
EOF
cp "$STUBS/uname" "$NO_SYSCTL/uname"
chmod +x "$STUBS/uname" "$STUBS/sysctl" "$NO_SYSCTL/uname"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$1" "$2"
    printf '      status=%s\n      stdout: %s\n      stderr: %s\n' \
        "$STATUS" "$(cat "$WORK/out")" "$(cat "$WORK/err")"
}

# run_case <path-dir> <uname -s> <uname -m> <sysctl mode>
# PATH holds only the stubs, so the sourced installer can reach nothing else.
run_case() {
    : > "$WORK/calls"
    env -i PATH="$1" HOME="$WORK/home" \
        STUB_OS="$2" STUB_ARCH="$3" STUB_SYSCTL="$4" STUB_CALLS="$WORK/calls" \
        STEROID_INSTALL_SOURCE_ONLY=1 INSTALL_SH="$INSTALL_SH" \
        "$TEST_SH_PATH" -c '. "$INSTALL_SH"; detect_platform; printf "PLATFORM=%s\n" "$PLATFORM_BINARY"' \
        > "$WORK/out" 2> "$WORK/err"
    STATUS=$?
}

sysctl_called() { [ -s "$WORK/calls" ]; }

# expect_binary <name> <expected binary> <rosetta note: yes|no> <sysctl consulted: yes|no>
expect_binary() {
    if [ "$STATUS" -ne 0 ]; then fail "$1" "expected success"; return; fi
    if ! grep -qxF "PLATFORM=$2" "$WORK/out"; then fail "$1" "expected $2"; return; fi
    if [ -s "$WORK/err" ]; then fail "$1" "unexpected stderr"; return; fi
    if [ "$3" = yes ]; then
        grep -qF -- "$ROSETTA_NOTE" "$WORK/out" || { fail "$1" "Rosetta note missing"; return; }
        [ "$(grep -c . "$WORK/out")" -eq 2 ] || { fail "$1" "note is not a single line"; return; }
    else
        ! grep -q Rosetta "$WORK/out" || { fail "$1" "unexpected Rosetta note"; return; }
    fi
    if [ "$4" = yes ]; then
        sysctl_called || { fail "$1" "sysctl was not consulted"; return; }
    else
        ! sysctl_called || { fail "$1" "sysctl should not be consulted"; return; }
    fi
    pass "$1"
}

# expect_refusal <name> <exact message>
expect_refusal() {
    if [ "$STATUS" -ne 1 ]; then fail "$1" "expected exit 1"; return; fi
    if grep -q '^PLATFORM=' "$WORK/out"; then fail "$1" "a binary was chosen"; return; fi
    if ! grep -qF -- "$2" "$WORK/err"; then fail "$1" "expected message: $2"; return; fi
    if grep -q Rosetta "$WORK/out"; then fail "$1" "unexpected Rosetta note"; return; fi
    pass "$1"
}

echo "detect_platform (sourced under $TEST_SH_PATH)"

run_case "$STUBS" Darwin arm64 fail
expect_binary "Darwin arm64" steroid-macos-arm64 no no

run_case "$STUBS" Darwin x86_64 1
expect_binary "Darwin x86_64, hw.optional.arm64=1 (Rosetta shell)" steroid-macos-arm64 yes yes

run_case "$STUBS" Darwin x86_64 0
expect_refusal "Darwin x86_64, hw.optional.arm64=0 (Intel)" "$INTEL_MSG"

run_case "$STUBS" Darwin x86_64 fail
expect_refusal "Darwin x86_64, sysctl fails (unknown oid)" "$INTEL_MSG"

run_case "$NO_SYSCTL" Darwin x86_64 unused
expect_refusal "Darwin x86_64, sysctl not on PATH" "$INTEL_MSG"

run_case "$STUBS" Darwin x86_64 1-then-fail
expect_refusal "Darwin x86_64, sysctl prints 1 but exits non-zero" "$INTEL_MSG"

run_case "$STUBS" Darwin x86_64 ""
expect_refusal "Darwin x86_64, sysctl prints nothing" "$INTEL_MSG"

run_case "$STUBS" Darwin i386 1
expect_refusal "Darwin i386 (unknown macOS arch)" "Unsupported macOS architecture: i386"

run_case "$STUBS" Linux x86_64 fail
expect_binary "Linux x86_64" steroid-linux-x86_64 no no

run_case "$STUBS" Linux aarch64 fail
expect_binary "Linux aarch64" steroid-linux-arm64 no no

run_case "$STUBS" Linux arm64 fail
expect_binary "Linux arm64" steroid-linux-arm64 no no

run_case "$STUBS" Linux armv7l fail
expect_refusal "Linux armv7l (unknown Linux arch)" "Unsupported Linux architecture: armv7l"

run_case "$STUBS" FreeBSD amd64 fail
expect_refusal "FreeBSD (unknown OS)" "Unsupported OS: FreeBSD. Use install.ps1 on Windows."

echo "install.sh structure"

# Sourcing with the guard set defines the functions and runs nothing.
STATUS=0
env -i PATH="$STUBS" HOME="$WORK/home" STEROID_INSTALL_SOURCE_ONLY=1 INSTALL_SH="$INSTALL_SH" \
    "$TEST_SH_PATH" -c '. "$INSTALL_SH"' > "$WORK/out" 2> "$WORK/err" || STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -s "$WORK/out" ] && [ ! -s "$WORK/err" ]; then
    pass "sourcing with STEROID_INSTALL_SOURCE_ONLY=1 runs nothing"
else
    fail "sourcing with STEROID_INSTALL_SOURCE_ONLY=1 runs nothing" "produced output or failed"
fi

# `curl | sh` runs the script as it streams in, so the call to main must stay
# the very last line: a truncated download then defines functions and stops.
: > "$WORK/out"; : > "$WORK/err"; STATUS=0
LAST="$(grep -v '^[[:space:]]*$' "$INSTALL_SH" | tail -n 1)"
if [ "$LAST" = '[ "${STEROID_INSTALL_SOURCE_ONLY:-0}" = 1 ] || main "$@"' ]; then
    pass "main is the last line, behind the source-only guard"
else
    fail "main is the last line, behind the source-only guard" "last line: $LAST"
fi

if grep -q 'arm64 runs via Rosetta' "$INSTALL_SH"; then
    fail "old Rosetta comment removed" "still present"
else
    pass "old Rosetta comment removed"
fi

if "$TEST_SH_PATH" -n "$INSTALL_SH" 2> "$WORK/err"; then
    pass "$TEST_SH -n install.sh"
else
    STATUS=$?; fail "$TEST_SH -n install.sh" "syntax error"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

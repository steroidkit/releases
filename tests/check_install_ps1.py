#!/usr/bin/env python3
"""Static checks for install.ps1 (no PowerShell needed).

install.ps1 runs as `irm ... | iex`, i.e. inside the user's own PowerShell
session, where `exit` closes their window. This checks that:

  * `exit` appears nowhere in code except the one guarded line at the very end;
  * braces, parentheses and brackets balance, ignoring string literals and
    comments (but not `$( ... )` subexpressions inside strings, which are code);
  * the only top-level statements are the param block, the Install-Steroid
    function and that final try/catch line;
  * Write-Fail throws, and the two early outs `return`;
  * -Force and $env:FORCE are both still honoured;
  * the top-level catch sets $global:LASTEXITCODE = 1 before its guarded exit;
  * the file is pure ASCII;
  * downloads name the exact release (releases/download/<tag>/, never
    releases/latest/download), the checksum is fetched before the binary,
    and a 404 on it falls back to the release's previous_version, read with
    ConvertFrom-Json behind a strict-mode-safe property check, one version
    back at most, failing with "Try again in an hour" otherwise; the version
    actually installed is what gets recorded.

ASCII matters because Windows PowerShell 5.1 reads a script without a BOM in
the ANSI code page: UTF-8 bytes such as the 0x94 in an em dash then decode to
U+201D, which PowerShell treats as a double quote, and the script mis-parses.
Any byte above 0x7F fails; as a second guard, the file is also re-scanned as
cp1252 and must tokenize the same.

Each run also breaks a copy of install.ps1 on purpose, in the ways these
checks exist for, and fails if a breakage goes unnoticed.

Usage: python3 tests/check_install_ps1.py [path/to/install.ps1]
"""
import re
import sys
from pathlib import Path

# PowerShell accepts typographic quotes as quote characters.
SINGLE_QUOTES = "'‘’‚‛"
DOUBLE_QUOTES = '"“”„'
COMMENT_STARTS_AFTER = " \t\r\n;(){}|,="

FINAL_LINE = (
    'try { Install-Steroid } catch { Write-Host "  [ERR] $($_.Exception.Message)"'
    " -ForegroundColor Red; $global:LASTEXITCODE = 1; if ($PSCommandPath) { exit 1 } }"
)
EXPECTED_TOP_LEVEL = ["param([switch]$Force)", "function Install-Steroid {", FINAL_LINE]
PAIRS = {")": "(", "]": "[", "}": "{"}


class Scanner:
    """Masks comments and string literals out of PowerShell source.

    `code` keeps the original text with every comment and string character
    replaced by a space (newlines kept, so offsets and line numbers still
    line up). Code inside a `$( ... )` subexpression in a double-quoted string
    is kept: it runs. `strings` marks which offsets are string content.
    """

    def __init__(self, text):
        self.text = text
        self.n = len(text)
        self.mask = [c if c == "\n" else " " for c in text]
        self.strings = [False] * self.n
        self.errors = []
        end = self._code(0)
        if end < self.n:
            self.errors.append((self.line(end), "unexpected ')'"))
        self.code = "".join(self.mask)

    def line(self, i):
        return self.text.count("\n", 0, i) + 1

    def _keep(self, i):
        self.mask[i] = self.text[i]

    def _code(self, i, in_subexpr=False):
        """Scan code from i. In a subexpression, stop after its closing ')'."""
        t, depth = self.text, 0
        while i < self.n:
            c = t[i]
            if c == "`":  # escape / line continuation
                self._keep(i)
                i += 2
                continue
            if t.startswith("<#", i):
                j = t.find("#>", i + 2)
                if j < 0:
                    self.errors.append((self.line(i), "unterminated <# comment"))
                    return self.n
                i = j + 2
                continue
            if c == "#" and (i == 0 or t[i - 1] in COMMENT_STARTS_AFTER):
                j = t.find("\n", i)
                i = self.n if j < 0 else j
                continue
            if c == "@" and i + 1 < self.n and t[i + 1] in SINGLE_QUOTES + DOUBLE_QUOTES:
                eol = t.find("\n", i)
                if eol >= 0 and not t[i + 2:eol].strip():
                    i = self._here_string(i, eol)
                    continue
            if c in SINGLE_QUOTES:
                i = self._single(i)
                continue
            if c in DOUBLE_QUOTES:
                i = self._double(i)
                continue
            if in_subexpr and c == "(":
                depth += 1
            elif in_subexpr and c == ")":
                if depth == 0:
                    self._keep(i)
                    return i + 1
                depth -= 1
            self._keep(i)
            i += 1
        if in_subexpr:
            self.errors.append((self.line(self.n), "unterminated $( subexpression"))
        return i

    def _single(self, start):
        i = start + 1
        while i < self.n:
            if self.text[i] in SINGLE_QUOTES:
                if i + 1 < self.n and self.text[i + 1] in SINGLE_QUOTES:
                    self.strings[i] = self.strings[i + 1] = True
                    i += 2
                    continue
                return i + 1
            self.strings[i] = True
            i += 1
        self.errors.append((self.line(start), "unterminated single-quoted string"))
        return self.n

    def _double(self, start):
        t, i = self.text, start + 1
        while i < self.n:
            c = t[i]
            if c == "`":
                self.strings[i] = True
                if i + 1 < self.n:
                    self.strings[i + 1] = True
                i += 2
                continue
            if c in DOUBLE_QUOTES:
                if i + 1 < self.n and t[i + 1] in DOUBLE_QUOTES:
                    self.strings[i] = self.strings[i + 1] = True
                    i += 2
                    continue
                return i + 1
            if c == "$" and i + 1 < self.n and t[i + 1] == "(":
                self._keep(i)
                self._keep(i + 1)
                i = self._code(i + 2, in_subexpr=True)
                continue
            self.strings[i] = True
            i += 1
        self.errors.append((self.line(start), "unterminated double-quoted string"))
        return self.n

    def _here_string(self, start, eol):
        closer = self.text[start + 1] + "@"
        m = re.compile(r"\n[ \t]*" + re.escape(closer)).search(self.text, eol)
        if not m:
            self.errors.append((self.line(start), "unterminated here-string"))
            return self.n
        for k in range(eol + 1, m.start()):
            self.strings[k] = True
        return m.end()


def balance_errors(sc):
    errors, stack = [], []
    for i, c in enumerate(sc.code):
        if c in "([{":
            stack.append((c, i))
        elif c in ")]}":
            if not stack or stack[-1][0] != PAIRS[c]:
                errors.append((sc.line(i), f"unmatched '{c}'"))
            else:
                stack.pop()
    errors += [(sc.line(i), f"unclosed '{c}'") for c, i in stack]
    return errors


def top_level_lines(sc):
    """Raw text of each line holding code outside every { } block."""
    depth, found = 0, []
    for i, c in enumerate(sc.code):
        if depth == 0 and not c.isspace():
            ln = sc.line(i)
            if ln not in found:
                found.append(ln)
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
    lines = sc.text.split("\n")
    return [(ln, lines[ln - 1].strip()) for ln in found]


def early_out_returns(lines, marker):
    """True if the block holding `marker` hits a bare `return` before closing."""
    for idx, line in enumerate(lines):
        if marker in line:
            for nxt in lines[idx + 1:]:
                s = nxt.strip()
                if s == "return":
                    return True
                if s.startswith("}"):
                    return False
    return False


def function_text(sc, name):
    """Raw text of `function <name> { ... }`, or '' if it isn't defined once."""
    starts = [m.start() for m in re.finditer(r"(?im)^\s*function\s+" + re.escape(name) + r"\s*\{", sc.code)]
    if len(starts) != 1:
        return ""
    depth = 0
    for i in range(sc.code.index("{", starts[0]), sc.n):
        if sc.code[i] == "{":
            depth += 1
        elif sc.code[i] == "}":
            depth -= 1
            if depth == 0:
                return sc.text[starts[0]:i + 1]
    return ""


def version_failures(sc, lines):
    """The exact-version download and the one-version-back fallback."""
    failures = []
    text = sc.text
    if "releases/latest/download" in text:
        failures.append("downloads must name the exact release (releases/download/<tag>/), "
                        "not releases/latest/download")

    # Main body order: resolve Latest, choose the version (checksum first),
    # then download the binary and install it.
    order = ["Get-LatestVersion", "Select-Version", "Download-Binary", "Install-Binary"]
    calls = [[k for k, l in enumerate(lines) if l.strip() == name] for name in order]
    if any(len(c) != 1 for c in calls) or [c[0] for c in calls] != sorted(c[0] for c in calls):
        failures.append(f"Install-Steroid must call {', '.join(order)} once each, in that order")

    fetch = function_text(sc, "Get-ReleaseFile")
    if '"https://github.com/$GITHUB_RELEASES_REPO/releases/download/$Tag/$Asset"' not in fetch:
        failures.append("Get-ReleaseFile must download releases/download/$Tag/$Asset")
    status = function_text(sc, "Get-HttpStatus")
    if "$ex.PSObject.Properties['Response']" not in status:
        failures.append("Get-HttpStatus must check for .Response before reading it (strict mode)")

    choose = function_text(sc, "Select-Version")
    steps = [
        ('Get-ReleaseFile $latest "$BinaryName.sha256"', "fetch the latest release's checksum first"),
        ("if ($status -ne 404)", "treat only a 404 as 'not ready yet'"),
        ('Get-ReleaseFile $latest "release-notes.json"', "read that release's release-notes.json"),
        ("Get-PreviousVersion $notes", "take previous_version from it"),
        ('Get-ReleaseFile "v$prev" "$BinaryName.sha256"', "fetch the previous version's checksum"),
        ('$script:InstallVersion = "v$prev"', "install the previous version"),
    ]
    at = 0
    for needle, what in steps:
        found = choose.find(needle, at)
        if found < 0:
            failures.append(f"Select-Version must {what}, in order ({needle!r})")
            break
        at = found + len(needle)
    if choose.count("Try again in an hour.") != 2 or not all(
            "Write-Fail" in l for l in choose.splitlines() if "Try again in an hour." in l):
        failures.append("Select-Version must Write-Fail with 'Try again in an hour.' when there's "
                        "no previous_version and when its file is missing too")
    if ('$notReady = "The Windows build of $latest isn\'t ready yet"' not in choose
            or '"$notReady, so installing v$prev. Steroid updates itself to $latest automatically once it is."'
            not in choose):
        failures.append("Select-Version must say which version it installs instead, and that it updates itself")
    # One version back at most: previous_version is read once, from the
    # latest release only.
    if len(re.findall(r"Get-PreviousVersion\s+\$", sc.code)) != 1:
        failures.append("Get-PreviousVersion must be called exactly once (never more than one version back)")

    prev = function_text(sc, "Get-PreviousVersion")
    for needle, what in [
        ("ConvertFrom-Json", "parse the manifest with ConvertFrom-Json"),
        ("$manifest.PSObject.Properties['previous_version']", "check previous_version exists (strict mode)"),
        ("'^[0-9]+\\.[0-9]+\\.[0-9]+$'", "accept only a plain X.Y.Z"),
    ]:
        if needle not in prev:
            failures.append(f"Get-PreviousVersion must {what}")

    download = function_text(sc, "Download-Binary")
    if "/releases/download/$($script:InstallVersion)/$BinaryName" not in download:
        failures.append("Download-Binary must download the binary of $script:InstallVersion")
    install = function_text(sc, "Install-Binary")
    records = ["$VersionBare = $script:InstallVersion -replace '^v', ''",
               '(Join-Path $InstallDir ".version") -Value $script:InstallVersion']
    if "LatestVersion" in download + install or not all(r in install for r in records):
        failures.append("Download-Binary and Install-Binary must use $script:InstallVersion (the version "
                        "actually installed) for versions\\<ver> and bin\\.version, never LatestVersion")
    return failures


def check(raw):
    """Return the list of failures for install.ps1's raw bytes."""
    failures = []
    text = raw.decode("utf-8", errors="replace")
    sc = Scanner(text)
    lines = text.split("\n")
    failures += [f"line {ln}: {msg}" for ln, msg in sc.errors]
    failures += [f"line {ln}: {msg}" for ln, msg in balance_errors(sc)]

    last = max((k for k, s in enumerate(lines) if s.strip()), default=0) + 1
    exits = sorted({sc.line(m.start()) for m in re.finditer(r"(?i)\bexit\b", sc.code)})
    if exits != [last]:
        failures.append(f"`exit` must appear only on the last line ({last}); found on lines {exits}")
    if lines[last - 1].rstrip() != FINAL_LINE:
        failures.append(f"last line is not the guarded try/catch: {lines[last - 1]!r}")
    if "$global:LASTEXITCODE = 1; if ($PSCommandPath)" not in lines[last - 1]:
        failures.append("the top-level catch must set $global:LASTEXITCODE = 1 before the $PSCommandPath check")
    for m in re.finditer(r"(?i)SetShouldExit|Stop-Process", sc.code):
        failures.append(f"line {sc.line(m.start())}: {m.group(0)} can end the user's session")

    top = top_level_lines(sc)
    if [s for _, s in top] != EXPECTED_TOP_LEVEL:
        failures.append(
            "top level must be only param, Install-Steroid and the try/catch line; found "
            + "; ".join(f"{ln}: {s}" for ln, s in top)
        )

    fail_defs = [l for l in lines if re.match(r"\s*function\s+Write-Fail\b", l)]
    if len(fail_defs) != 1 or not re.search(r"\bthrow\b", fail_defs[0]):
        failures.append(f"Write-Fail must be defined once and throw: {fail_defs}")
    for marker in ("is already installed", "nothing changed."):
        if not early_out_returns(lines, marker):
            failures.append(f"the '{marker}' path must `return`")
    if "$Force -or ($env:FORCE -eq '1')" not in text:
        failures.append("-Force / $env:FORCE handling is missing")
    for needed in ("Set-StrictMode -Version Latest", "$ErrorActionPreference = 'Stop'"):
        if needed not in text:
            failures.append(f"missing: {needed}")
    failures += version_failures(sc, lines)

    # Pure ASCII, so no code page can change how the script parses. This also
    # rejects a BOM (EF BB BF).
    non_ascii = sorted({raw.count(b"\n", 0, i) + 1 for i, b in enumerate(raw) if b > 0x7F})
    if non_ascii:
        failures.append(f"bytes above 0x7F on lines {non_ascii} (the file must be pure ASCII)")
    # Second guard: Windows PowerShell 5.1 reads a BOM-less file as cp1252.
    # Re-scan it that way; the code outside strings and comments must not
    # change (0x82/0x84/0x91-0x94 decode to typographic quotes).
    ansi = "".join(chr(b) if b in (0x81, 0x8D, 0x8F, 0x90, 0x9D) else bytes([b]).decode("cp1252") for b in raw)
    ansi_sc = Scanner(ansi)
    if re.sub(r"\s", "", ansi_sc.code) != re.sub(r"\s", "", sc.code):
        problems = ansi_sc.errors + balance_errors(ansi_sc)
        failures.append(
            "read as cp1252 (Windows PowerShell 5.1, file without BOM) the script "
            f"tokenizes differently ({len(problems)} string/brace errors)"
        )
    return failures


def self_test():
    """The scanner ignores strings and comments, and keeps $( ) code."""
    sc = Scanner("a '}(' \"{ `\" $(exit) }\" # exit {\n<# ) #> b")
    assert sc.errors == [], sc.errors
    assert "exit" in sc.code and "}" not in sc.code.replace("$(exit)", ""), sc.code
    assert balance_errors(Scanner("f { (x) ")) == [(1, "unclosed '{'")]
    assert balance_errors(Scanner("'{' \"}\" x")) == []
    assert Scanner("'it''s' \"a \"\"b\"\"\" x").code.strip() == "x"
    assert Scanner("“x” y").code.strip() == "y"  # smart quotes are quotes
    assert Scanner("@'\n } \n'@ z").code.strip() == "z"
    fails = check(("param([switch]$Force)\nfunction Install-Steroid {\n exit 0\n}\n" + FINAL_LINE + "\n").encode())
    assert any("`exit` must appear only" in f for f in fails), fails


# Ways install.ps1 could be broken that the checks above must catch:
# (what, text to replace, replacement). Each runs against a copy of the real file.
BREAKAGES = [
    ("downloads via releases/latest/download",
     "releases/download/$Tag/$Asset", "releases/latest/download/$Asset"),
    ("the binary from the latest release, not the version chosen",
     "releases/download/$($script:InstallVersion)/$BinaryName", "releases/download/$($script:LatestVersion)/$BinaryName"),
    ("the version isn't chosen before the download",
     "    Get-LatestVersion\n    Select-Version\n", "    Get-LatestVersion\n"),
    ("the binary downloaded before the version is chosen",
     "    Select-Version\n", "    Download-Binary\n    Select-Version\n"),
    ("any failure counts as 'not ready yet'",
     "if ($status -ne 404)", "if ($false)"),
    ("previous_version read without the strict-mode check",
     "if ($manifest -and $manifest.PSObject.Properties['previous_version'])", "if ($manifest.previous_version)"),
    ("previous_version accepted unvalidated",
     "'^[0-9]+\\.[0-9]+\\.[0-9]+$'", "'.'"),
    ("falls back two versions",
     '$script:InstallVersion = "v$prev"',
     '$prev = Get-PreviousVersion $notes; $script:InstallVersion = "v$prev"'),
    ("the fallback failure exits",
     'Write-Fail "$notReady, and v$prev', 'exit 1; Write-Fail "$notReady, and v$prev'),
    ("a fallback failure without 'Try again in an hour.'",
     "and there's no earlier version to install instead. Try again in an hour.",
     "and there's no earlier version to install instead."),
    ("bin\\.version records the latest, not the version installed",
     "-Value $script:InstallVersion -Encoding ASCII", "-Value $script:LatestVersion -Encoding ASCII"),
    ("versions\\<ver> named after the latest",
     "$VersionBare = $script:InstallVersion -replace", "$VersionBare = $script:LatestVersion -replace"),
    ("the plan's wording pasted with a typographic apostrophe",
     "build of $latest isn't ready yet", "build of $latest isn’t ready yet"),
    ("Get-HttpStatus reads .Response unguarded",
     "if ($ex.PSObject.Properties['Response'] -and $ex.Response)", "if ($ex.Response)"),
]


def breakage_test(raw):
    """Each BREAKAGES entry must make check() fail. Returns what went unnoticed."""
    text = raw.decode("utf-8")
    missed = []
    for what, old, new in BREAKAGES:
        if text.count(old) != 1:
            missed.append(f"{what}: the text to break isn't in install.ps1 exactly once ({old!r})")
        elif not check(text.replace(old, new).encode("utf-8")):
            missed.append(f"{what}: not caught")
    return missed


def main():
    self_test()
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "install.ps1"
    raw = path.read_bytes()
    failures = check(raw)
    if not failures:
        failures = [f"breakage check: {m}" for m in breakage_test(raw)]
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"{path.name}: {len(failures)} failure(s)")
        return 1
    print(f"{path.name}: ok (pure ASCII, no stray exit, balanced, guarded exit + LASTEXITCODE, throw/return, "
          f"-Force/$env:FORCE, exact-version downloads + one-version fallback; {len(BREAKAGES)} breakages caught)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

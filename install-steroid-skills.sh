#!/usr/bin/env sh
# Steroid onboarding-skills installer  —  GENERATED FILE, DO NOT EDIT BY HAND.
# Regenerate with:  python scripts/build_skill_installer.py
#
# Adds steroid's onboarding slash-command skills to your coding agent so you can
# run /steroid-onboard, which installs the steroid CLI itself. No steroid install
# is required to use this script.
#
#   curl -fsSL https://raw.githubusercontent.com/steroidkit/releases/main/install-steroid-skills.sh | sh
#   # into every known agent:   ... | sh -s -- --all
#   # force a specific agent:    ... | sh -s -- --cursor
#
set -eu

log() { printf '  %s\n' "$*"; }
ok()  { printf '  \033[32m+\033[0m %s\n' "$*"; }
err() { printf '  \033[31mx\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Install steroid onboarding skills into your coding agent(s).

Usage: install-steroid-skills.sh [--all | --claude | --cursor | --codex | --copilot]

With no options, auto-detects installed agents (~/.claude, ~/.cursor, ~/.codex,
~/.copilot) and installs into each; falls back to Claude Code if none are found.
Then restart your agent and run /steroid-onboard.
USAGE
}

base_dir_for() {
  case "$1" in
    claude)  echo "$HOME/.claude" ;;
    cursor)  echo "$HOME/.cursor" ;;
    codex)   echo "$HOME/.codex" ;;
    copilot) echo "$HOME/.copilot" ;;
  esac
}

skills_dir_for() {
  case "$1" in
    claude)  echo "$HOME/.claude/skills" ;;
    cursor)  echo "$HOME/.cursor/skills" ;;
    codex)   echo "$HOME/.codex/skills" ;;
    copilot) echo "$HOME/.copilot/skills" ;;
  esac
}

install_skills_into() {
  base="$1"
  mkdir -p "$base"
  mkdir -p "$base/steroid-onboard"
  cat > "$base/steroid-onboard/SKILL.md" <<'STEROID_SKILL_EOF'
---
name: steroid-onboard
description: Install and onboard the Steroid CLI in LOCAL mode agentically — download the binary if missing, set local mode, wire the user's coding agents (Cursor, Claude Code, Codex, Copilot), index a project, and verify. Use when the user wants to set up / onboard steroid, or invokes /steroid-onboard. Everything runs locally; no account or connection string is required.
---

# steroid-onboard

Drive the whole Steroid **local-mode** setup for the user without the interactive TUI: install the CLI, pick local mode, wire each requested coding agent to steroid, index a project's chat history, and hand back a verified report. You are orchestrating a sequence of `steroid` CLI commands and healing each step from its machine-readable output.

This skill is **standalone** — it bootstraps steroid itself, so don't assume steroid is installed yet.

## Usage

```
/steroid-onboard mode=local ides=cursor,claude-code project=/absolute/path/to/project
```

All three are optional on the command line — ask for whatever the user didn't supply (see Inputs).

## Inputs

Parse these from the user's message (e.g. `/steroid-onboard mode=local ides=cursor,claude-code project=/Users/me/app`). Ask only for what's missing:

- **mode** — only `local` is supported here. If the user asks for `connected`, say that's out of scope for this skill and stop.
- **ides** — comma-separated subset of: `cursor`, `claude-code`, `codex`, `copilot`. If omitted, ask which agents they use. Reject anything outside that set.
- **project** — absolute path to the project root to index. If omitted, ask. Verify it exists and is a directory before using it.

Before making changes, tell the user in one line what you'll do (install steroid if needed, set local mode, wire <ides>, index <project>). Invoking this skill is authorization to proceed — keep them informed, don't ask permission for each step. Never delete files or run destructive git.

## The steroid binary

Resolve it once and reuse it — after a fresh install the new `PATH` entry is **not** active in this shell, so rely on the absolute wrapper path:

```sh
STEROID="$(command -v steroid || echo "$HOME/.local/bin/steroid")"
```

Every command below is `"$STEROID" …`. Prefer parsing each command's `--json` over its exit code, but exit codes are a fast signal.

## Steps

### 1. Install or confirm the CLI
Run `"$STEROID" --version`. If it works, skip to step 2. If the binary is missing, install it:

```sh
curl -fsSL https://raw.githubusercontent.com/steroidkit/releases/main/install.sh | sh
```

Then re-resolve `STEROID` and re-run `--version`.

- **If the install can't reach GitHub (`raw.githubusercontent.com` / `api.github.com`):** this is almost always a corporate VPN / secure-web-gateway blocking the *download* (the installed binary itself runs fine on or off VPN). Tell the user to disable the VPN just for the download, then retry this step. **Without a working binary you cannot continue — stop here and report.**

### 2. Set local mode (must come before wiring any IDE)
```sh
"$STEROID" mode set local
"$STEROID" mode show --json    # confirm {"mode":"local", ...}
```
Order matters: which skills get installed depends on the mode, so set it first.

### 3. Wire each requested IDE
For each ide, run:
```sh
"$STEROID" setup <ide> --skip-health-probe --json
```
`--skip-health-probe` keeps this fast and non-interactive (the live agent check can hang ~30–60s or trigger a sign-in prompt, and it's non-blocking anyway — especially skip it for the agent you're running inside, to avoid calling yourself recursively).

Parse the JSON: `{"ide","ok","configured","steps":[…],"failed_step","failure_kind"}`.
- `ok: true` → the IDE is wired (MCP config, instructions, skills written). Record it as **configured**. A `health_probe` step with `status:"warn"` is fine — note it, don't treat it as failure.
- `ok: false` → a real blocker failed. Read `failed_step` + `failure_kind` + the failing step's `message`/`action_url` and heal per the table below, then **continue to the next IDE** (partial success is fine — don't abort the whole run for one agent).

Exit codes: `0` wired · `1` blocker failed · `2` unknown ide.

### 4. Start the background daemon (best-effort)
```sh
"$STEROID" daemon start
```
This runs the local chat-history sync loop. If it fails (common in a dev checkout with no installed binary), note it and move on — it's non-fatal.

### 5. Index the project
```sh
"$STEROID" project add "<project>"     # registers + builds the chat-memory index
```
Capture the output. Exit non-zero means registration failed (report it). A line containing `error:` means a per-agent index build failed (surface it for healing). `No chat history found` is **not** an error — see step 6.

### 6. Verify and report
```sh
"$STEROID" memory list   --project "<project>" --json    # {"indexed_ides":[…]}
"$STEROID" memory status --project "<project>" --json    # {"sources":[{ide,nodes,lines,…}]}
```

Distinguish two different things in your report — this matters:
- **Configured** = the agent's MCP is wired (from step 3). 
- **Indexed data for this project** = the agent appears in `indexed_ides`. For a brand-new project with no past chats, this list is legitimately **empty** — that is expected success, not a failure. Data appears here as the user actually works in the project.

## Failure healing reference

| `failure_kind` | Meaning | Heal |
|---|---|---|
| `cli_not_found` | The agent's **CLI** (its command-line tool) isn't on PATH | Ask the user to install **that agent's CLI specifically** — the command-line tool, e.g. Cursor's `agent`, Codex's `codex`, Claude Code's `claude`, Copilot's `copilot` — using the step's `action_url`. State plainly you mean the **CLI, not the desktop app**. Offer to skip this ide and continue. Never install it or sign in for them. |
| `app_not_found` | The agent's **desktop app** isn't installed (Cursor / Claude Code only) | Ask the user to install the **desktop application** from `action_url`; skip + continue |
| `config_error` | Couldn't write the MCP/instruction config | Surface the `message` (often a permissions or malformed-JSON issue); retry once; if it persists, report and skip |
| `probe_auth` / `probe_timeout` | Live check only (non-blocking) | Note it; the IDE is still wired. They can sign in later and run `"$STEROID" setup <ide> --check` |

All commands are idempotent — after healing a step, just re-run this skill; it resumes cleanly.

**Only ever give instructions for third-party agent tools — never auto-install them or perform their login.** When you ask the user to install something, name it precisely: the agent's **CLI** (command-line tool: `agent` / `codex` / `claude` / `copilot`) is a different thing from its **desktop app** — say which one explicitly so the two can't be conflated. Cursor and Claude Code have both a CLI and an app; Codex and Copilot are CLI-only.

## Final report

End with a compact status the user can act on:

```
Steroid onboarding — PASS   (or: NEEDS ATTENTION)
Mode:    local
Project: <path>  (registered: yes)

IDEs configured (MCP wired):
  ✓ cursor
  ✓ claude-code
  ⚠ codex — skipped: Codex CLI not installed → <action_url>

Indexed chat data for this project:
  ✓ claude-code — 12 nodes
  – cursor — no chats yet for this project (expected; indexes as you use it)

Daemon: running
Next:   restart each wired IDE so steroid appears in its MCP tools.
```

Treat it as **PASS** when: the binary works, mode is `local`, at least one IDE is configured, and the project registered + built without an `error:`. Otherwise mark **NEEDS ATTENTION** and name the exact failing step, its `failure_kind`/`message`, and the heal action — so the user (or you, on re-run) can fix that one point and proceed.

## Notes

- Local mode only. No connection string, account, or network is required beyond the one-time binary download.
- Wiring an IDE edits that agent's real MCP config (e.g. `~/.cursor/mcp.json`, `~/.claude.json`). That's expected and idempotent.
- After setup, each wired IDE must be **restarted** to load steroid's MCP server.
STEROID_SKILL_EOF
  ok "steroid-onboard  ->  $base/steroid-onboard/SKILL.md"

}

FORCE=""
for arg in "$@"; do
  case "$arg" in
    --all)     FORCE="claude cursor codex copilot" ;;
    --claude)  FORCE="$FORCE claude" ;;
    --cursor)  FORCE="$FORCE cursor" ;;
    --codex)   FORCE="$FORCE codex" ;;
    --copilot) FORCE="$FORCE copilot" ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $arg"; usage; exit 2 ;;
  esac
done

TARGETS=""
if [ -n "$FORCE" ]; then
  TARGETS="$FORCE"
else
  for a in claude cursor codex copilot; do
    if [ -d "$(base_dir_for "$a")" ]; then TARGETS="$TARGETS $a"; fi
  done
  if [ -z "$TARGETS" ]; then
    log "No coding agent detected - defaulting to Claude Code (~/.claude/skills)."
    TARGETS="claude"
  fi
fi

log "Installing steroid onboarding skills: steroid-onboard"
for a in $TARGETS; do
  d="$(skills_dir_for "$a")"
  log "-> $a  ($d)"
  install_skills_into "$d"
done

printf '\n'
ok "Done. Restart your agent if it was open, then run:  /steroid-onboard"

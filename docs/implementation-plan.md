# Claude Attribution Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `Co-Authored-By: Claude` attribution mechanically enforced (not prompt-level best-effort) for every commit created from a Claude Code session — including subagent commits, local merges, and `gh pr merge` — across all repos on a developer machine.

**Architecture:** Two enforcement layers, both versioned in this repo under `tools/attribution/` with an installer. Layer 1 is a machine-global git `prepare-commit-msg` hook (via `core.hooksPath`) that appends the trailer whenever `CLAUDECODE=1` is in the environment; it chains to any repo-local hook so existing repos keep working. Layer 2 is a Claude Code `PreToolUse` hook that blocks `gh pr merge` commands whose merge-commit body lacks the trailer, forcing Claude to retry with `--subject`/`--body` (merge commits are created server-side by GitHub, so no git hook can reach them).

**Tech Stack:** POSIX sh (git hook), Python 3 stdlib (PreToolUse hook — parses JSON from stdin; python3 3.14 is on PATH), bash test scripts (no test framework; these are standalone scripts outside the npm/TypeScript toolchain).

## Global Constraints

- Trailer text, exactly: `Co-Authored-By: Claude <noreply@anthropic.com>` (matches all 60 existing attributed commits).
- The git hook must be a no-op unless the environment variable `CLAUDECODE` equals `1` (Claude Code sets this in every shell it spawns, including subagents'; a human's normal terminal doesn't have it).
- The git hook must never break a commit: any unexpected condition → exit 0 without modifying the message. A hook failure that aborts commits machine-wide is worse than a missing trailer.
- The git hook must chain to the repo-local hook at `$(git rev-parse --git-path hooks)/prepare-commit-msg` if one exists and is executable (repos using plain `.git/hooks`). Repos that set local `core.hooksPath` (husky, lefthook) already override the global path entirely and need no chaining.
- The PreToolUse hook must only ever block (exit 2 + stderr guidance) or allow (exit 0). It must not rewrite commands. On malformed stdin JSON → exit 0 (fail open).
- `gh pr merge --rebase` produces no merge commit → must be allowed without a trailer.
- Local merge commits DO get the trailer (decided in review: they are Claude's work; git's `prepare-commit-msg` receives source arg `merge` for them and we do not skip it). `squash` source is also processed.
- No changes to how humans work: manual commits and web-UI merges are out of scope for enforcement (web-UI/auto-merge is only fixable in GitHub repo settings — documented, not implemented).
- All new files live under `tools/attribution/`; nothing under `src/` changes; the npm test suite is untouched.

## File Structure

```
tools/attribution/
├── README.md                      # What this is, why prompt-level attribution leaks, install & uninstall
├── prepare-commit-msg             # Layer 1: global git hook (POSIX sh)
├── require-merge-attribution.py   # Layer 2: Claude Code PreToolUse hook (Python 3, stdlib only)
├── install.sh                     # Copies hooks into place, sets git config, patches ~/.claude/settings.json
└── test/
    ├── test-prepare-commit-msg.sh       # Exercises the git hook in throwaway repos
    └── test-require-merge-attribution.sh # Feeds sample PreToolUse JSON to the Python hook
```

Installed locations (what `install.sh` produces):
- `~/.git-hooks/prepare-commit-msg` + `git config --global core.hooksPath ~/.git-hooks`
- `~/.claude/hooks/require-merge-attribution.py` + a `hooks.PreToolUse` entry in `~/.claude/settings.json`

---

### Task 1: Global git hook (`prepare-commit-msg`)

**Files:**
- Create: `tools/attribution/prepare-commit-msg`
- Test: `tools/attribution/test/test-prepare-commit-msg.sh`

**Interfaces:**
- Consumes: git's `prepare-commit-msg` contract — `$1` = path to the commit-message file, `$2` = source (`message`, `template`, `merge`, `squash`, `commit`, or empty), `$3` = SHA (unused). Environment: `CLAUDECODE`.
- Produces: the message file ends with the exact trailer line `Co-Authored-By: Claude <noreply@anthropic.com>` (preceded by a blank line) whenever `CLAUDECODE=1`; the file is untouched otherwise. Chains to the repo-local hook. `install.sh` (Task 3) copies this file verbatim to `~/.git-hooks/prepare-commit-msg`.

- [ ] **Step 1: Write the failing test**

Create `tools/attribution/test/test-prepare-commit-msg.sh`:

```bash
#!/usr/bin/env bash
# Tests for tools/attribution/prepare-commit-msg.
# Each test builds a throwaway git repo, installs the hook under test as the
# repo's ONLY hook path, commits, and inspects the resulting message.
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/prepare-commit-msg"
TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'
FAILURES=0

make_repo() {  # $1 = dir
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
  # Simulate the global hooksPath install: point this repo at a dir holding our hook.
  mkdir -p "$1/global-hooks"
  cp "$HOOK" "$1/global-hooks/prepare-commit-msg"
  chmod +x "$1/global-hooks/prepare-commit-msg"
  git -C "$1" config core.hooksPath "$(cd "$1/global-hooks" && pwd)"
}

check() {  # $1 = description, $2 = expected (present|absent), $3 = repo dir
  local body
  body="$(git -C "$3" log -1 --format=%B)"
  local has=absent
  case "$body" in *"$TRAILER"*) has=present ;; esac
  if [ "$has" = "$2" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (trailer $has, expected $2)"; echo "--- message ---"; echo "$body"
    FAILURES=$((FAILURES + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. CLAUDECODE=1 → trailer appended
make_repo "$TMP/r1"
echo a > "$TMP/r1/f"; git -C "$TMP/r1" add f
CLAUDECODE=1 git -C "$TMP/r1" commit -qm "feat: something"
check "appends trailer when CLAUDECODE=1" present "$TMP/r1"

# 2. No CLAUDECODE → untouched
make_repo "$TMP/r2"
echo a > "$TMP/r2/f"; git -C "$TMP/r2" add f
env -u CLAUDECODE git -C "$TMP/r2" commit -qm "manual commit"
check "leaves manual commits alone" absent "$TMP/r2"

# 3. Trailer already present → not duplicated
make_repo "$TMP/r3"
echo a > "$TMP/r3/f"; git -C "$TMP/r3" add f
CLAUDECODE=1 git -C "$TMP/r3" commit -qm "feat: x

$TRAILER"
count="$(git -C "$TMP/r3" log -1 --format=%B | grep -cF "$TRAILER")"
if [ "$count" -eq 1 ]; then echo "ok: no duplicate trailer"; else
  echo "FAIL: no duplicate trailer (found $count)"; FAILURES=$((FAILURES + 1)); fi

# 4. Local merge commit → trailer appended
make_repo "$TMP/r4"
echo a > "$TMP/r4/f"; git -C "$TMP/r4" add f
env -u CLAUDECODE git -C "$TMP/r4" commit -qm "base"
git -C "$TMP/r4" checkout -qb feature
echo b > "$TMP/r4/g"; git -C "$TMP/r4" add g
env -u CLAUDECODE git -C "$TMP/r4" commit -qm "feature work"
git -C "$TMP/r4" checkout -q master 2>/dev/null || git -C "$TMP/r4" checkout -q main
echo c > "$TMP/r4/h"; git -C "$TMP/r4" add h
env -u CLAUDECODE git -C "$TMP/r4" commit -qm "diverge"
CLAUDECODE=1 git -C "$TMP/r4" merge -q --no-edit --no-ff feature
check "attributes local merge commits" present "$TMP/r4"

# 5. Chains to repo-local hook (plain .git/hooks) — local hook adds a marker line
make_repo "$TMP/r5"
LOCAL_HOOKS="$(git -C "$TMP/r5" rev-parse --git-path hooks)"
case "$LOCAL_HOOKS" in /*) : ;; *) LOCAL_HOOKS="$TMP/r5/$LOCAL_HOOKS" ;; esac
mkdir -p "$LOCAL_HOOKS"
printf '#!/bin/sh\necho "local-hook-ran" >> "$1"\n' > "$LOCAL_HOOKS/prepare-commit-msg"
chmod +x "$LOCAL_HOOKS/prepare-commit-msg"
echo a > "$TMP/r5/f"; git -C "$TMP/r5" add f
CLAUDECODE=1 git -C "$TMP/r5" commit -qm "feat: chained"
body="$(git -C "$TMP/r5" log -1 --format=%B)"
case "$body" in *local-hook-ran*) echo "ok: chains to repo-local hook" ;;
  *) echo "FAIL: chains to repo-local hook"; FAILURES=$((FAILURES + 1)) ;; esac
check "trailer still added when chaining" present "$TMP/r5"

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0
else echo "$FAILURES TEST(S) FAILED"; exit 1; fi
```

Then: `chmod +x tools/attribution/test/test-prepare-commit-msg.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `tools/attribution/test/test-prepare-commit-msg.sh`
Expected: FAIL — `cp` errors because `tools/attribution/prepare-commit-msg` does not exist yet, and every check reports FAIL. Exit code 1.

- [ ] **Step 3: Write the hook**

Create `tools/attribution/prepare-commit-msg`:

```sh
#!/bin/sh
# Global prepare-commit-msg hook (installed to ~/.git-hooks by
# tools/attribution/install.sh, activated via `git config --global core.hooksPath`).
#
# Appends the Claude co-author trailer to commits made from Claude Code
# sessions (CLAUDECODE=1 — set by Claude Code in every shell it spawns,
# including subagents'). Attribution via prompt instructions alone is
# best-effort and leaks on subagent commits and local merges; this hook
# closes that gap mechanically. Human commits (no CLAUDECODE) pass through
# untouched.
#
# Must never abort a commit: every unexpected condition exits 0.

MSG_FILE="$1"

# Chain to the repo-local hook first, so repos with plain .git/hooks keep
# working under the global core.hooksPath. (Repos that set a local
# core.hooksPath, e.g. husky, bypass this file entirely — git only ever
# runs one hooks dir, and local config wins.)
LOCAL_HOOK="$(git rev-parse --git-path hooks 2>/dev/null)/prepare-commit-msg"
if [ -n "$MSG_FILE" ] && [ -x "$LOCAL_HOOK" ] && [ "$LOCAL_HOOK" != "$0" ]; then
  "$LOCAL_HOOK" "$@" || exit $?
fi

[ "${CLAUDECODE:-}" = "1" ] || exit 0
[ -n "$MSG_FILE" ] && [ -w "$MSG_FILE" ] || exit 0

TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'

if ! grep -qF "$TRAILER" "$MSG_FILE" 2>/dev/null; then
  # Blank line before the trailer so git parses it as a trailer, not body text.
  printf '\n%s\n' "$TRAILER" >> "$MSG_FILE" 2>/dev/null || exit 0
fi

exit 0
```

Then: `chmod +x tools/attribution/prepare-commit-msg`

- [ ] **Step 4: Run the test to verify it passes**

Run: `tools/attribution/test/test-prepare-commit-msg.sh`
Expected: all 6 checks print `ok:`, final line `ALL TESTS PASSED`, exit 0.

Note: test 4 relies on git putting the merge message through `prepare-commit-msg` with an editable file even with `--no-edit`; if that check alone fails on this git version, re-run the merge without `--no-edit` using `GIT_EDITOR=true` and keep the assertion unchanged.

- [ ] **Step 5: Commit**

```bash
git add tools/attribution/prepare-commit-msg tools/attribution/test/test-prepare-commit-msg.sh
git commit -m "feat(attribution): global prepare-commit-msg hook stamping Claude trailer"
```

---

### Task 2: Claude Code PreToolUse hook (`require-merge-attribution.py`)

**Files:**
- Create: `tools/attribution/require-merge-attribution.py`
- Test: `tools/attribution/test/test-require-merge-attribution.sh`

**Interfaces:**
- Consumes: Claude Code's PreToolUse hook contract — a JSON object on stdin with at least `{"tool_name": "Bash", "tool_input": {"command": "<the shell command>"}}`. Exit 0 = allow the tool call; exit 2 = block it and feed stderr back to Claude as correction guidance.
- Produces: blocks any `gh pr merge` whose command line lacks the trailer `Co-Authored-By: Claude <noreply@anthropic.com>`, with stderr explaining the exact `--subject`/`--body` recipe. Allows everything else. `install.sh` (Task 3) copies this file to `~/.claude/hooks/require-merge-attribution.py` and registers it in `~/.claude/settings.json`.

- [ ] **Step 1: Write the failing test**

Create `tools/attribution/test/test-require-merge-attribution.sh`:

```bash
#!/usr/bin/env bash
# Feeds sample PreToolUse JSON payloads to require-merge-attribution.py and
# asserts on the exit code (0 = allow, 2 = block).
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/require-merge-attribution.py"
FAILURES=0

run() {  # $1 = description, $2 = expected exit code, $3 = json payload
  printf '%s' "$3" | python3 "$HOOK" >/dev/null 2>&1
  local code=$?
  if [ "$code" -eq "$2" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (exit $code, expected $2)"
    FAILURES=$((FAILURES + 1))
  fi
}

json() {  # $1 = command string → PreToolUse payload, safely JSON-escaped
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'

run "blocks gh pr merge without trailer" 2 \
  "$(json 'gh pr merge 30 --merge')"

run "blocks squash merge without trailer" 2 \
  "$(json 'gh pr merge 30 --squash --subject "title (#30)"')"

run "allows merge with trailer in --body" 0 \
  "$(json "gh pr merge 30 --merge --subject 'Merge pull request #30 from EG-A-S/x' --body 'Title

$TRAILER'")"

run "allows --rebase (no merge commit exists)" 0 \
  "$(json 'gh pr merge 30 --rebase')"

run "allows unrelated gh commands" 0 \
  "$(json 'gh pr view 30 --json title')"

run "allows unrelated bash commands" 0 \
  "$(json 'git status')"

run "allows non-Bash tools" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'

run "fails open on malformed JSON" 0 'this is not json'

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0
else echo "$FAILURES TEST(S) FAILED"; exit 1; fi
```

Then: `chmod +x tools/attribution/test/test-require-merge-attribution.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `tools/attribution/test/test-require-merge-attribution.sh`
Expected: FAIL — python3 can't open the missing hook file, so the "blocks" cases exit 2's expectation is unmet (python exits 2 on unopenable file — if so, the "allows" cases fail instead; either way at least one FAIL line and exit 1).

- [ ] **Step 3: Write the hook**

Create `tools/attribution/require-merge-attribution.py`:

```python
#!/usr/bin/env python3
"""Claude Code PreToolUse hook: refuse `gh pr merge` without Claude attribution.

Merge commits from `gh pr merge` are created server-side by GitHub, so no
local git hook can stamp them. This hook blocks the command (exit 2) unless
the trailer is already in the command line, and tells Claude the exact
recipe to retry with. Everything else is allowed (exit 0). Fails open.
"""
import json
import re
import sys

TRAILER = "Co-Authored-By: Claude <noreply@anthropic.com>"

GUIDANCE = f"""gh pr merge blocked: the merge commit must carry Claude attribution.
GitHub creates this commit server-side, so the trailer has to be in the
command itself. Retry like this (keep GitHub's default subject format):

  gh pr view <nr> --json title,headRefName   # get title and branch first

  # merge commit:  subject = "Merge pull request #<nr> from <owner>/<branch>"
  # squash commit: subject = "<PR title> (#<nr>)"
  gh pr merge <nr> --merge \\
    --subject "Merge pull request #<nr> from <owner>/<branch>" \\
    --body "<PR title>

{TRAILER}"

(--rebase needs no attribution: it creates no merge commit.)"""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # fail open: never brick unrelated tool calls

    if payload.get("tool_name") != "Bash":
        return 0

    command = (payload.get("tool_input") or {}).get("command") or ""

    if not re.search(r"\bgh\s+pr\s+merge\b", command):
        return 0
    if "--rebase" in command:
        return 0
    if TRAILER in command:
        return 0

    print(GUIDANCE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

Then: `chmod +x tools/attribution/require-merge-attribution.py`

- [ ] **Step 4: Run the test to verify it passes**

Run: `tools/attribution/test/test-require-merge-attribution.sh`
Expected: all 8 checks print `ok:`, final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tools/attribution/require-merge-attribution.py tools/attribution/test/test-require-merge-attribution.sh
git commit -m "feat(attribution): PreToolUse hook blocking unattributed gh pr merge"
```

---

### Task 3: Installer, README, and machine activation

**Files:**
- Create: `tools/attribution/install.sh`
- Create: `tools/attribution/README.md`
- Modify (machine-global, not in repo): `~/.git-hooks/`, `~/.claude/hooks/`, `~/.claude/settings.json`, global git config

**Interfaces:**
- Consumes: `tools/attribution/prepare-commit-msg` (Task 1, copied verbatim) and `tools/attribution/require-merge-attribution.py` (Task 2, copied verbatim).
- Produces: an idempotent `install.sh` any colleague can run. After it runs: `git config --global core.hooksPath` → `~/.git-hooks`; `~/.claude/settings.json` contains a `hooks.PreToolUse` entry with matcher `Bash` invoking `~/.claude/hooks/require-merge-attribution.py`.

- [ ] **Step 1: Write the installer**

Create `tools/attribution/install.sh`:

```bash
#!/usr/bin/env bash
# Installs both Claude-attribution enforcement layers on this machine.
# Idempotent: safe to re-run after pulling updates to the hook scripts.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
GIT_HOOKS_DIR="$HOME/.git-hooks"
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

# --- Layer 1: global git hook -------------------------------------------
EXISTING_HOOKS_PATH="$(git config --global core.hooksPath || true)"
if [ -n "$EXISTING_HOOKS_PATH" ] && [ "$EXISTING_HOOKS_PATH" != "$GIT_HOOKS_DIR" ]; then
  echo "error: core.hooksPath already set to '$EXISTING_HOOKS_PATH'." >&2
  echo "Merge $SRC/prepare-commit-msg into that directory manually." >&2
  exit 1
fi
mkdir -p "$GIT_HOOKS_DIR"
cp "$SRC/prepare-commit-msg" "$GIT_HOOKS_DIR/prepare-commit-msg"
chmod +x "$GIT_HOOKS_DIR/prepare-commit-msg"
git config --global core.hooksPath "$GIT_HOOKS_DIR"
echo "installed: $GIT_HOOKS_DIR/prepare-commit-msg (core.hooksPath set)"

# --- Layer 2: Claude Code PreToolUse hook --------------------------------
mkdir -p "$CLAUDE_HOOKS_DIR"
cp "$SRC/require-merge-attribution.py" "$CLAUDE_HOOKS_DIR/require-merge-attribution.py"
chmod +x "$CLAUDE_HOOKS_DIR/require-merge-attribution.py"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" "$CLAUDE_HOOKS_DIR/require-merge-attribution.py" <<'PY'
import json, sys

settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)

command = f"python3 {hook_path}"
hooks = settings.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])

already = any(
    h.get("command") == command
    for entry in pre
    for h in entry.get("hooks", [])
)
if not already:
    pre.append({
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": command}],
    })
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"registered PreToolUse hook in {settings_path}")
else:
    print(f"PreToolUse hook already registered in {settings_path}")
PY

echo "done. Restart any running Claude Code sessions to pick up the settings change."
```

Then: `chmod +x tools/attribution/install.sh`

- [ ] **Step 2: Write the README**

Create `tools/attribution/README.md`:

```markdown
# Claude attribution enforcement

Claude Code's attribution (`Co-Authored-By: Claude <noreply@anthropic.com>`)
is a prompt-level instruction, so it silently leaks:

- **Subagent commits** — helper agents don't receive the instruction.
- **Merge commits** — `gh pr merge` commits are created server-side by
  GitHub; local `git merge` messages are auto-generated by git. Claude
  never writes either message. (In this repo, 0 of 20 merge commits were
  attributed; ~27 subagent commits were missed.)

This directory makes attribution mechanical instead:

| Layer | File | Covers |
|---|---|---|
| Global git hook | `prepare-commit-msg` | All local commits and local merges from any Claude session (keyed on the `CLAUDECODE=1` env var Claude Code sets — subagents included). Human commits untouched. |
| Claude Code PreToolUse hook | `require-merge-attribution.py` | Blocks `gh pr merge` unless the trailer is in the merge-commit `--body`; Claude retries with the correct command. |

**Not covered:** merges via the GitHub web UI or auto-merge — those can only
be fixed in GitHub repo settings (commit-message defaults / merge-queue
config).

## Install

    tools/attribution/install.sh

Idempotent. Refuses to clobber a pre-existing custom `core.hooksPath`.
Repos using husky/lefthook (which set a *local* `core.hooksPath`) bypass
the global hook and are unaffected; repos with plain `.git/hooks` hooks are
chained to automatically.

## Uninstall

    git config --global --unset core.hooksPath
    rm ~/.git-hooks/prepare-commit-msg ~/.claude/hooks/require-merge-attribution.py

…and remove the `hooks.PreToolUse` entry referencing
`require-merge-attribution.py` from `~/.claude/settings.json`.

## Counting attributed work

    # commits (trailer)
    git log --all --grep="Co-Authored-By: Claude" --oneline

    # PRs (footer is markdown-linked, so match loosely)
    gh pr list --state all --limit 100 --json number,title,url,body \
      --jq '.[] | select(.body | test("Generated with \\[?Claude Code"))'

Merge commits should be classified by whether the **PR they merge** carries
the footer — never by the merge message itself (pre-hook history has none).

## Tests

    tools/attribution/test/test-prepare-commit-msg.sh
    tools/attribution/test/test-require-merge-attribution.sh
```

- [ ] **Step 3: Run the installer**

Run: `tools/attribution/install.sh`
Expected output lines: `installed: … (core.hooksPath set)`, `registered PreToolUse hook in …/settings.json`, `done. …`.

- [ ] **Step 4: Verify the machine state**

```bash
git config --global core.hooksPath            # → /Users/<you>/.git-hooks
test -x ~/.git-hooks/prepare-commit-msg && echo "git hook ok"
test -x ~/.claude/hooks/require-merge-attribution.py && echo "claude hook ok"
python3 -c "import json; s=json.load(open('$HOME/.claude/settings.json')); print(json.dumps(s['hooks']['PreToolUse'], indent=2))"
```

Expected: hooksPath printed, both `ok` lines, and one PreToolUse entry with matcher `Bash`.

- [ ] **Step 5: End-to-end smoke test (real global hook, throwaway repo)**

```bash
TMP=$(mktemp -d) && git init -q "$TMP" && cd "$TMP" \
  && git config user.email t@t && git config user.name t \
  && echo x > f && git add f \
  && CLAUDECODE=1 git commit -qm "smoke: attribution hook" \
  && git log -1 --format=%B
cd - && rm -rf "$TMP"
```

Expected: message body ends with `Co-Authored-By: Claude <noreply@anthropic.com>`. (This exercises the *installed* hook via real global `core.hooksPath`, unlike Task 1's tests which simulate it.)

Also verify idempotence: run `tools/attribution/install.sh` a second time; expected `PreToolUse hook already registered`, and the settings file gains no duplicate entry.

- [ ] **Step 6: Commit**

```bash
git add tools/attribution/install.sh tools/attribution/README.md
git commit -m "feat(attribution): installer and docs for the enforcement hooks"
```

---

## Out of scope (documented decisions)

- **Web-UI / auto-merge merges:** only fixable in GitHub repo settings; noted in the README, no implementation.
- **PR body footers (`gh pr create`, `gh pr comment`):** stays prompt-level. History shows PR bodies almost always got the footer; commits were the leak. Add a second PreToolUse matcher later if it ever becomes a problem (YAGNI).
- **Backfilling history:** never rewrite published history to add trailers. For reporting, use the counting recipes in the README.

#!/usr/bin/env bash
# Installs both Claude-attribution enforcement layers on this machine.
# Idempotent: safe to re-run after pulling updates to the hook scripts.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
GIT_HOOKS_DIR="$HOME/.git-hooks"
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required but not found on PATH." >&2
  exit 1
}

# Refuse to run at all if settings.json exists but is not valid JSON —
# fail before any machine state is touched, with an actionable message.
if [ -f "$SETTINGS" ] && ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS" 2>/dev/null; then
  echo "error: $SETTINGS is not valid JSON. Fix or back it up, then re-run." >&2
  exit 1
fi

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
import json, os, shlex, sys, tempfile

settings_path, hook_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, OSError):
    print(f"error: {settings_path} is not valid JSON. Fix or back it up, then re-run.", file=sys.stderr)
    sys.exit(1)

command = f"python3 {shlex.quote(hook_path)}"
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
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(settings_path) or ".", prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, settings_path)
    except BaseException:
        os.unlink(tmp_path)
        raise
    print(f"registered PreToolUse hook in {settings_path}")
else:
    print(f"PreToolUse hook already registered in {settings_path}")
PY

echo "done. Restart any running Claude Code sessions to pick up the settings change."

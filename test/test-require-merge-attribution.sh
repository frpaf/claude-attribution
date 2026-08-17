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

run "allows -r short rebase flag" 0 \
  "$(json 'gh pr merge 30 -r')"

run "blocks merge with --rebase only inside quoted body text" 2 \
  "$(json 'gh pr merge 30 --merge --body "never use --rebase here"')"

run "allows unrelated gh commands" 0 \
  "$(json 'gh pr view 30 --json title')"

run "allows unrelated bash commands" 0 \
  "$(json 'git status')"

run "allows non-Bash tools" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'

run "fails open on malformed JSON" 0 'this is not json'

run "fails open on valid non-object JSON" 0 '[1, 2, 3]'

run "fails open on non-dict tool_input" 0 \
  '{"tool_name":"Bash","tool_input":"oops"}'

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0
else echo "$FAILURES TEST(S) FAILED"; exit 1; fi

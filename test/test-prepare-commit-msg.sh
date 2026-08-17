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
LOCAL_HOOKS="$(git -C "$TMP/r5" rev-parse --git-dir)/hooks"
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

# 6. Chaining works from a linked worktree (hooks live in the common dir)
make_repo "$TMP/r6"
echo a > "$TMP/r6/f"; git -C "$TMP/r6" add f
env -u CLAUDECODE git -C "$TMP/r6" commit -qm "base"
LOCAL_HOOKS6="$(git -C "$TMP/r6" rev-parse --git-dir)/hooks"
case "$LOCAL_HOOKS6" in /*) : ;; *) LOCAL_HOOKS6="$TMP/r6/$LOCAL_HOOKS6" ;; esac
mkdir -p "$LOCAL_HOOKS6"
printf '#!/bin/sh\necho "local-hook-ran" >> "$1"\n' > "$LOCAL_HOOKS6/prepare-commit-msg"
chmod +x "$LOCAL_HOOKS6/prepare-commit-msg"
git -C "$TMP/r6" worktree add -q "$TMP/r6-wt" -b wt-branch
git -C "$TMP/r6-wt" config core.hooksPath "$(cd "$TMP/r6/global-hooks" && pwd)"
echo b > "$TMP/r6-wt/g"; git -C "$TMP/r6-wt" add g
CLAUDECODE=1 git -C "$TMP/r6-wt" commit -qm "feat: from worktree"
body6="$(git -C "$TMP/r6-wt" log -1 --format=%B)"
case "$body6" in *local-hook-ran*) echo "ok: chains to local hook from a worktree" ;;
  *) echo "FAIL: chains to local hook from a worktree"; FAILURES=$((FAILURES + 1)) ;; esac
check "trailer still added from a worktree" present "$TMP/r6-wt"

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0
else echo "$FAILURES TEST(S) FAILED"; exit 1; fi

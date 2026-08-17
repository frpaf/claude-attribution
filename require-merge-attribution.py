#!/usr/bin/env python3
"""Claude Code PreToolUse hook: refuse `gh pr merge` without Claude attribution.

Merge commits from `gh pr merge` are created server-side by GitHub, so no
local git hook can stamp them. This hook blocks the command (exit 2) unless
the trailer is already in the command line, and tells Claude the exact
recipe to retry with. Everything else is allowed (exit 0). Fails open.
"""
import json
import re
import shlex
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

    if not isinstance(payload, dict):
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0

    command = tool_input.get("command")
    if not isinstance(command, str):
        return 0

    if not re.search(r"\bgh\s+pr\s+merge\b", command):
        return 0

    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()

    if "--rebase" in tokens or "-r" in tokens:
        return 0
    if TRAILER in command:
        return 0

    print(GUIDANCE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

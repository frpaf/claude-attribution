---
description: Merge a PR with the required Claude co-author trailer in the merge/squash commit
argument-hint: <pr-number> [--merge|--squash|--rebase]
---

Merge PR `$ARGUMENTS` (default strategy: `--merge` if none of `--merge`/`--squash`/`--rebase` is given).

Follow these steps exactly:

1. Run `gh pr view <pr-number> --json title,headRefName,state,mergeable` and confirm the PR
   is actually mergeable (not already merged/closed, no conflicts). Stop and report if it isn't.

2. Pick the strategy from the arguments (default `--merge`).

3. If the strategy is `--rebase`: just run
   `gh pr merge <pr-number> --rebase`
   No merge commit is created, so no attribution trailer is needed. Done.

4. Otherwise, build the subject and body:
   - `--merge`: subject is `Merge pull request #<pr-number> from <owner>/<headRefName>`
     (get `<owner>` from the repo, e.g. via `gh repo view --json owner -q .owner.login`
     or from `headRefName` if it already includes an owner/fork prefix).
   - `--squash`: subject is `<PR title> (#<pr-number>)`.
   - Body: the PR title, a blank line, then exactly this trailer line:
     `Co-Authored-By: Claude <noreply@anthropic.com>`

5. Run it, e.g.:
   ```
   gh pr merge <pr-number> --merge \
     --subject "Merge pull request #<pr-number> from <owner>/<branch>" \
     --body "<PR title>

   Co-Authored-By: Claude <noreply@anthropic.com>"
   ```

6. Report the merge commit SHA/URL back once done.

Note: if the `require-merge-attribution.py` PreToolUse hook from this repo is installed, it will
block a `gh pr merge` call that's missing the trailer and print retry guidance — if that happens,
just follow its instructions and retry with the trailer included.

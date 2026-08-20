---
description: Commit current changes on a branch, PR, merge, delete the branch, return to main, pull, and rebuild the app
argument-hint: [optional subject or branch hint]
allowed-tools: Bash, Read, Edit, Grep
---

Ship the current working-tree changes end to end. `$ARGUMENTS` — if present — is a hint at the subject or branch name; otherwise derive both from the diff.

## Steps

1. **Check there is something to ship.** `git status --short`. If the tree is clean, stop and say so — do not invent a change.

2. **Read the diff before naming anything.** `git diff` and `git diff --staged`. The branch name, commit message and PR body all come from what actually changed, not from the user's phrasing.

3. **Branch.** If on `main`, `git checkout -b <type>/<kebab-summary>` (`fix/`, `feat/`, `chore/`, `docs/`). If already on a topic branch, stay on it.

4. **Commit.** Stage only files related to this change — never `git add -A` blind. Write the message the way this repo does: a short imperative subject, then prose explaining *why*, wrapped at ~72 columns. Match the tone of `git log`. End with the required trailers.

5. **Push and PR.** `git push -u origin <branch>`, then `gh pr create`. The body should state the problem, the fix, and any tradeoff a reader would want flagged. Include concrete evidence (command output, before/after values) where the change is behavioural.

6. **Merge and clean up.** `gh pr merge <n> --merge --delete-branch`, then `git checkout main && git pull`. Confirm `git branch` shows only `main`.

7. **Rebuild.** `./build-app.sh`. This is the only way to actually run OneBar — a bare `swift build` produces a binary that can't behave as a menubar accessory.

8. **Verify the install** and show the output:

   ```sh
   codesign -dv --verbose=2 /Applications/OneBar.app 2>&1 | grep -E "Identifier|Signature"
   codesign -d -r- /Applications/OneBar.app 2>/dev/null | tail -1
   codesign --verify --verbose=2 /Applications/OneBar.app 2>&1 | tail -2
   pgrep -x OneBar
   ```

   The designated requirement must read `designated => identifier "com.onebar.app"`. If it ever comes back as `cdhash H"..."`, the explicit `-r=` in `build-app.sh` has been lost and the Accessibility grant will break on the next rebuild — say so loudly rather than continuing.

## Rules

- If the build fails, stop before merging anything and report the error.
- Never force-push, never `git reset --hard`, never rewrite pushed history.
- If the changes look like two unrelated things, say so and ask whether to split them rather than bundling them into one PR.
- Report what actually happened. If a step was skipped or a check failed, state it plainly.

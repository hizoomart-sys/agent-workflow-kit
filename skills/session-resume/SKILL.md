---
name: session-resume
description: Restore context at the start of a session from RESUME.md and route by status. Use on "продолжаем", "дальше", "поехали", "continue", "resume", as the first message or after /clear, and on "что у нас по проекту", "полный статус", "project status".
---

# Session resume

The SessionStart hook already injects RESUME.md after `/clear` and `/compact`. This skill covers the manual path (first message "продолжаем" / "continue").

## 1. Find RESUME

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session/session-resolve.sh" resume
```

- prints a path -> read that file
- prints `SESSION_RESUME_AMBIGUOUS` -> this branch has no RESUME of its own and the root one belongs to another session. Do NOT use the root RESUME. Check `git worktree list` and `git log --oneline -15 --all`, or ask "what are we continuing?"
- empty output -> no RESUME: read the top block of `.planning/CONTEXT.md`, else `git log -5`

## 2. Route by `status` (missing = in_progress)

- `complete`: do not stop. Look for the next work in `.planning/FOLLOWUPS.md` or `BACKLOG.md`; show the next step. Nothing found -> "[where] is done. What next?"
- `waiting_user`: "Waiting on: [human_pending]. Next step: [next]."
- `in_progress`: card with `-> [next]`, `!= [blockers]`, `X [avoid]`, `~ [infra]` (non-empty only).

## 3. Git drift

If `last_commit` differs from `git log -1 --pretty=%h%x20%s`, add "N commits since the save."

## 4. Return to the branch (before any code edit)

If the card contains `session_branch:`, the previous work is NOT in the base branch and a fresh worktree cut from base will not contain it. Say "The work is on branch `<branch>`, not in base" and offer `git checkout <branch>` or a live worktree of that branch (`git worktree list`). Do not start edits from base without checking. No such field -> the work was merged, starting from base is correct.

## 5. Full status

"что у нас по проекту" / "полный статус": RESUME plus the top 2-3 blocks of `.planning/CONTEXT.md`.

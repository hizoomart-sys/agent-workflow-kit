---
name: parallel-sessions
description: Work in an isolated git worktree per Claude session, merge it back with --no-ff, and commit only your own files. Use when starting work in a repo with the kit enabled, when edits to the main checkout get blocked, on "параллельные сессии", "worktree", "влей сессию", "смержи ветку сессии", "wt start", "wt merge", "почисти ветки сессий", or when several sessions share one checkout.
---

# Parallel sessions

Each session works in its own git worktree `<repo>/<worktreeDir>/<sid8>` on branch `<prefix>/<sid8>` cut from `<base>`. The main checkout is protected from edits. A finished branch is merged back with `--no-ff` and the worktree is removed.

`<sid8>` is the first 8 characters of `CLAUDE_CODE_SESSION_ID`.

## Enable

Create `<repo>/.claude/workflow-kit.json`. Without `"enabled": true` every hook is a silent no-op.

```json
{
  "enabled": true,
  "prefix": "claude",
  "worktreeDir": ".claude/worktrees",
  "base": "main",
  "planningDir": ".planning",
  "enforce": "block",
  "linkFiles": [".env.local"],
  "testCommand": ""
}
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Master switch for hooks and the `wt` commands. |
| `prefix` | `"claude"` | Session branches are `<prefix>/<sid8>`. |
| `worktreeDir` | `".claude/worktrees"` | Where worktrees and their manifests live (relative to the repo). It is added to `.git/info/exclude`. |
| `base` | `"main"` | Branch that sessions start from and merge into. |
| `planningDir` | `".planning"` | Planning directory (shared with the sessions module). |
| `enforce` | `"block"` | `block`: edits in the main checkout are denied. `warn`: allowed with a warning in context. |
| `linkFiles` | `[]` | Untracked files of the main checkout to symlink into each new worktree (secrets, local env files). Relative paths only. |
| `testCommand` | `""` | Run in the worktree before merging; non-zero exit refuses the merge. Empty = no check. |

## Locate the tool

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree/wt" <command>
```

## Start of a session

1. If the SessionStart hook said the session is in the main checkout, or an edit was blocked, run:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree/wt" start
   ```

   It creates the worktree and branch (idempotent), writes the manifest, symlinks `linkFiles`, prints `WORKTREE_PATH=...` and `BRANCH=...`.
2. `cd` into `WORKTREE_PATH` and use absolute paths inside it for every Edit/Write. The guard allows edits only inside a linked worktree.
3. `wt start --launch` additionally starts `claude` in the new worktree (for use from a terminal, not from inside a session).

## Commit only your own files

The checkout may hold changes from other sessions or from the user. Never sweep them into your commit.

- Stage explicit paths of files you edited in this session: `git add path/a path/b`. Never `git add -A`, `git add .` or `git commit -a` in a shared checkout.
- Before committing, list what you are about to commit (`git diff --cached --name-only`) and check every path against the files you touched. Unstage anything else.
- Files you did not touch stay unstaged and are not mentioned in the commit.

Inside your own worktree nobody else writes, so the same discipline mostly protects the main checkout and any worktree you share.

## Merge back

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree/wt" merge [SID] [--dry-run] [--push] [--cleanup-only] [--force]
```

- `SID` defaults to the session branch of the current directory, else `CLAUDE_CODE_SESSION_ID`.
- Refused when: the worktree has uncommitted files, the branch has no commits over `<base>`, the main checkout has modified tracked files, or `testCommand` fails.
- If `origin` exists, `<base>` is fast-forwarded from it first (a diverged base only warns).
- Merges with `--no-ff` into `<base>` in the main checkout. On conflict the merge is aborted and nothing is deleted.
- Afterwards the worktree and the branch are removed. No push unless `--push`.
- `--dry-run`: runs the checks and prints the plan, changes nothing.
- `--cleanup-only`: removes the worktree and branch without merging (empty or throwaway session). Refuses if the branch has commits or the tree is dirty unless `--force`. A backup ref `refs/wt-trash/<ts>-<sid>` is always written.
- Your shell is probably inside the worktree that gets removed: `cd` to the printed main checkout path afterwards.

The Stop hook suggests merging when a session branch ends with unmerged work. Ask the operator before merging: it changes shared history.

## Status and cleanup

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree/wt" status
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree/wt" doctor [--gc] [--reap-idle] [--prune-remote]
```

- A branch with a live worktree is never classified as safe to delete (`ACTIVE_*`).
- `--gc` removes only local branches without a worktree whose content is already in `<base>`, after writing `refs/wt-trash/<ts>-<sid>`. Restore: `git branch <name> refs/wt-trash/<ts>-<sid>`. Backups older than 30 days are dropped. Remote branches are untouched.
- A SessionStart hook runs `--gc` in the background; sessions with a fresh manifest (under 24 h) are skipped.

## Emergency bypass of the main-checkout guard

- Environment: start Claude Code with `WT_ALLOW_MAIN=1`.
- Temporary file read by the guard runner (here for guard name `worktree`, 10 minutes):

  ```
  mkdir -p ~/.claude/workflow-kit/run/guard-bypass
  printf 'expires_at=%s\nreason=%s\n' "$(( $(date +%s) + 600 ))" "why" > ~/.claude/workflow-kit/run/guard-bypass/worktree
  ```

  Delete the file to cancel early. Expired or malformed files are removed automatically.
- The guard runs fail-closed: if the guard script itself crashes or times out, edits are blocked with `GUARD_INTERNAL_ERROR`; the bypass file works even then.

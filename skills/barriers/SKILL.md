---
name: barriers
description: What the kit's blocking hooks (barriers) stop and why, how to bypass them legitimately, and how to add your own barrier through guard-runner. Use when a command or a Stop was blocked by "BLOCKED", "GUARD_INTERNAL_ERROR", "VERIFICATION REQUIRED", or on "барьер", "guard", "почему заблокировало", "обойти барьер", "добавить барьер".
---

# Barriers

A rule that only prints a warning gets ignored; a barrier that exits 2 holds. The kit ships hooks that block instead of advise.

| Barrier | Event | Blocks | Why |
|---|---|---|---|
| destructive-git | PreToolUse (Bash) | `git push --force` / `-f` / `+refspec` (not `--force-with-lease`), `reset --hard`, `clean -f`, `branch -D`, `merge <prefix>/*` without `--no-ff` | Irreversible loss; a fast-forward hides the merge in `git log --merges`. Judged on the parsed command, so quoted data (echo, heredoc, grep pattern) passes and `$(...)`, `&&`, `nice -n 10 git ...` do not. `<prefix>` is `prefix` from `.claude/workflow-kit.json`, default `claude`. |
| verify-before-stop | Stop | A "done / fixed / works / готово" claim after Write/Edit with no Bash/Read/Grep/Glob call after the last edit in the turn | Claims without a check are the usual way broken work gets reported as finished. |
| save-session-silence-guard | Stop | Any prose after the save-session final marker, except one fence starting with `продолжаем` | The marker is only text the script prints; this enforces it. |
| wiring-health | SessionStart | Nothing. Warns once if a hook script from `hooks.json` is missing, an interpreter (node, python3, git) is absent, or a barrier fired 200+ times in 14 days | A silently dead barrier looks the same as a quiet one. |

## Bypass legitimately

- Preferred: the user runs the blocked command in their own terminal. Do not retry a blocked command verbatim; ask the user.
- Temporary, per guard (guard-runner checks it before running the hook, works even if the hook is dead; 10 minutes here):

```bash
mkdir -p ~/.claude/workflow-kit/run/guard-bypass
printf 'expires_at=%s\nreason=%s\n' "$(( $(date +%s) + 600 ))" "why" > ~/.claude/workflow-kit/run/guard-bypass/destructive-git
```

The file name is the guard `--name`. Delete the file to end the bypass early; an expired or malformed file removes itself. Stop barriers loop-protect via `stop_hook_active` (they block once per turn).

## Add your own barrier

1. Write a script that reads the hook JSON on stdin, prints the reason to **stderr** and exits 2 to block, 0 to allow. Exit 0 quietly on anything you do not understand, unless it must fail closed.
2. Wire it in `hooks/hooks.json` through the runner so crashes and timeouts are normalised:

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guards/guard-runner.sh --name my-guard --fail-mode block --timeout 8 -- "${CLAUDE_PLUGIN_ROOT}"/scripts/guards/my-guard.sh
```

`--fail-mode block` makes an internal error (exit 1, timeout, missing interpreter) block with `GUARD_INTERNAL_ERROR`; `warn` lets it through with a diagnostic. Wiring a script directly, without the runner, is fail-open: a crash silently disables it.
3. Optional: `require('./lib/fire-log.js').logFire(name, 'block', 'reason')` records firings for wiring-health's loud-barrier check.
4. Add a test that breaks the rule on purpose and expects red. A green test on a dead mechanism is worse than none.

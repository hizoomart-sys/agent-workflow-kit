---
name: session-save
description: Save the session state via save-session.py (CONTEXT.md + RESUME.md + the "продолжаем" fence). Use on "сохраняемся", "сохрани сессию", "сохрани контекст", "завершаем сессию", "закрываем сессию", "save session", "save context", "wrap up the session".
---

# Session save

One call to the script does everything: appends a block to `.planning/CONTEXT.md`, rotates old blocks into `CONTEXT-archive-YYYY-MM.md`, regenerates `.planning/RESUME.md`, prints a session card and the resume fence. Do not perform these steps by hand.

## Locate the script

`${CLAUDE_PLUGIN_ROOT}/scripts/session/save-session.py`

## Body format

Write the body to a scratchpad file with the Write tool, then feed it via stdin (avoids long inline commands):

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/session/save-session.py" "<short title>" < <body-file>
```

Body = bullets only, at most 25 lines. Field names are Russian; English aliases are accepted and canonicalized.

| Field (RU / EN alias) | Meaning |
|---|---|
| `Сделано` / `Done` | what was finished (reference commit hashes for big diffs) |
| `Не сделано` / `Not done`, `todo`, `blockers` | open items |
| `Следующий шаг` / `Next` | self-contained next step: `path/file.py:42` or an exact command. The next session reads it first and alone; never "see items below" |
| `Что не сработало` / `Avoid` | tried X, failed because Y |
| `Инфра` / `Infra` | things needing deploy, reload or a manual action on infrastructure |
| `Ждёт пользователя` / `Waiting on user` (`human_pending`) | waiting for the user's answer, review or manual action |
| `Решения-инсайты` / `Insights`, `Decisions` | decisions and lessons |
| `Файлы` / `Files` | key paths, one `- <absolute path> (why)` per line below the field; they go into the fence |

Fenced code, prose and unknown fields are dropped by the slimmer (a warning lists unknown fields).

## Status mapping (mandatory)

- waiting for the user -> fill `Ждёт пользователя:` (status `waiting_user`)
- unfinished step -> fill `Следующий шаг:` (status `in_progress`)
- infra action pending -> `Инфра:` (status `in_progress`)
- all of these empty AND nothing is pending -> only then pass `--complete` explicitly.

`complete` means the session has no tail, not that the feature is verified. Empty fields without `--complete` make the script refuse with exit code 4 before writing anything. Re-run with the fields filled; never edit RESUME.md by hand.

## Flags

- `--commit` commit the context files (opt-in)
- `--complete` explicit "no tail"
- `--dry-run` show the card, write nothing
- `--sid <id>` address your session explicitly (default: `$CLAUDE_CODE_SESSION_ID`)

## Output discipline

1. Before the script: a 1-2 line report of what was committed or deployed.
2. The script prints the card and the final marker `⟦save-session: конец вывода — ничего больше не печатать⟧`.
3. After the marker: exactly one artifact, the code block starting with `продолжаем ...` (copy the fence from the script output). No other prose.

If the user also asked for commit/push or merge: do add/commit/push BEFORE the script. A merge that removes the worktree goes AFTER, silently (tool calls only). Do not merge unless the user explicitly asked for it.

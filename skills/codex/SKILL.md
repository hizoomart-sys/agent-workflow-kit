---
name: codex
description: Hand a read-only job to the Codex CLI (ChatGPT subscription) to save Claude's limit or get an independent check — diff-risk (GO/NO-GO on the uncommitted change), review (line-level findings on a diff), audit (whole codebase), followup (ask the last Codex session more). Use on "/codex", "codex diff", "codex ревью", "codex аудит", "codex проверь проект", "codex уточни".
---

# Codex bridge

`${CLAUDE_PLUGIN_ROOT}/scripts/codex/codex-bridge.sh` runs `codex exec` with `-s read-only` — Codex reads the project and never writes. Auth is the ChatGPT subscription from `codex login`; no API key is used unless `--api` is passed.

## When to call

Call when there is an artifact to check (a diff, a codebase, a log) and the call either saves Claude's limit on a long read-only analysis or lowers risk before an irreversible step.
Do not call when Claude answers in a minute, the question is about product or wording, the user must be asked anyway, or Claude already holds the needed context.

## Step 1 — Mode

| Request | Mode |
|---|---|
| "is it safe to ship", "what will this break", "риски изменений" | diff-risk — our prompt, GO/NO-GO + confidence |
| "find bugs in the diff", "code review" | review — Codex's native review, `[P0/P1] file:line` |
| "audit the project", "проверь проект" | audit, `--scope general|auth|env-deploy|observability|tests|architecture|security` |
| "ask it more", "уточни у codex" | followup — resumes the last Codex session, context is not resent |

Unclear → one line: "Mode: diff-risk / review / audit / followup?".

## Step 2 — Run

```bash
CB="${CLAUDE_PLUGIN_ROOT}/scripts/codex/codex-bridge.sh"
"$CB" diff-risk --proj "$(pwd)"
"$CB" review [--uncommitted | --base BRANCH | --commit SHA] --proj "$(pwd)"
"$CB" audit --proj "$(pwd)" --scope security
"$CB" followup --question "..." --proj "$(pwd)"
"$CB" run --prompt-file FILE --proj "$(pwd)"          # any custom read-only prompt
```

`--proj` is the repository root (`git rev-parse --show-toplevel`). Audit and large diffs take minutes — use `run_in_background`.

Model and reasoning: `--model`, `--effort low|medium|high|xhigh|max|ultra`. Defaults: diff-risk/run/followup → `AWK_CODEX_MODEL` or `gpt-5.6-terra`, medium; audit/review → `AWK_CODEX_MODEL_DEEP` or `gpt-5.6-sol`, high. The model is always passed explicitly because the Codex desktop app rewrites `~/.codex/config.toml`. If your plan lacks these models, set the env variables.

## Step 3 — Show

```
Codex [<mode>] — model: <CODEX_MODEL> / effort: <CODEX_EFFORT> / auth: <CODEX_AUTH>
CONFIDENCE: <confidence> | GO: <go_allowed>

<CODEX_TEXT>
```

diff-risk with `GO_ALLOWED no` → say plainly that Codex advises against shipping and why. The verdict is advice, not a gate: what actually blocks shipping is a deterministic check (tests, secrets in the diff), not a model's opinion.

Codex cannot write, so Claude saves the report if the project keeps them — ask once where (for example `.planning/reviews/<mode>-YYYY-MM-DD.md`), do not create folders in someone else's project.

## Failures

- `noauth` → ask the user to run `codex login`. Never move to the paid API silently.
- `quota` → 45 minute cooldown, the script refuses calls until it ends (`===CODEX_COOLDOWN===` seconds). Do the analysis yourself and say it is Claude's, not Codex's. `--api` (needs `OPENAI_API_KEY` in the environment, billed per token) only on the user's explicit yes.
- `error` → show the `===CODEX_ERR===` tail, offer to retry. The raw stream path is in `===CODEX_RAW===`.

---
name: second-opinion
description: Ask outside models for a second opinion — Codex (GPT, ChatGPT subscription) and optionally Gemini (Google API key) — then pick one answer with a stated reason. Modes solve (bug, choice of approach), research (current facts with web search), review (Codex reviews the current diff), audit (Codex audits the whole codebase). Use on "второе мнение", "спроси модели", "что думают другие модели", "second opinion", "/second-opinion".
---

# Second Opinion

Claude writes a self-contained prompt, outside models answer independently, Claude selects. Two scripts do all the I/O:

- `${CLAUDE_PLUGIN_ROOT}/scripts/models/ask-models.sh` — solve / research: Gemini and Codex in parallel.
- `${CLAUDE_PLUGIN_ROOT}/scripts/codex/codex-bridge.sh` — review / audit: Codex alone, read-only.

## Requirements

- Codex CLI logged in with a ChatGPT plan: `npm install -g @openai/codex`, then `codex login`.
- Optional Gemini leg: `GEMINI_API_KEY` exported in the shell that starts Claude Code. Without it Codex answers alone (`===GEMINI_FALLBACK=== nokey`); say so once, do not ask for the key.
- `jq`, `curl`, `python3`.
- Keys come only from the environment. Never read `.env` files, never put a key in a prompt or a command line.

## Step 1 — Mode

Explicit argument wins. Otherwise by the request:

| Mode | When |
|---|---|
| solve | a bug, a stack trace, a weak solution, "how better", alternatives |
| research | facts that change over time: prices, versions, releases, comparisons |
| review | "review this fix / this diff" — scope is the uncommitted change |
| audit | "audit the project / find every place / architecture" — scope is the whole codebase |

Unclear → ask in one line: "Mode: solve / research / review / audit?". Print `Mode: <mode>`.

Do not ask when Claude answers well alone and the step is reversible: a weaker model in the loop can pull a strong answer down. Ask when stakes are high (auth, payments, data loss, irreversible changes) or Claude's own answer is unstable.

## Step 2 — Prompt (solve, research)

Fill the template from context in the user's language: `references/solve.txt` (two files: shared body plus a different role suffix per model) or `references/research.txt` (one file). Write to `mktemp` files. Never show the prompt to the user, and keep secrets and personal data out of it.

## Step 3 — Call

```bash
SO="${CLAUDE_PLUGIN_ROOT}/scripts/models/ask-models.sh"
CB="${CLAUDE_PLUGIN_ROOT}/scripts/codex/codex-bridge.sh"
"$SO" solve --gemini-prompt "$GFILE" --gpt-prompt "$PFILE" [--img PATH ...]
"$SO" research --prompt "$PFILE" [--img PATH ...]
"$CB" review [--uncommitted | --base BRANCH | --commit SHA] --proj "$(pwd)"
"$CB" audit --proj "$(pwd)" [--scope general|auth|env-deploy|observability|tests|architecture|security]
```

Research and audit can run for minutes: start them with `run_in_background` and read the result when it lands.

## Step 4 — Read the sentinels

| Sentinel | Meaning | Do |
|---|---|---|
| `===CODEX_TEXT===` | Codex answered | use it |
| `===CODEX_FALLBACK=== noauth` | no ChatGPT login | ask the user to run `codex login`; never switch to the paid API silently |
| `===CODEX_FALLBACK=== quota` | plan quota used up, 45 min cooldown (`===CODEX_COOLDOWN===` seconds) | answer with the other leg; paid API (`run --api`, needs `OPENAI_API_KEY`) only on the user's explicit yes |
| `===CODEX_FALLBACK=== error` | other failure, tail in `===CODEX_ERR===` | answer with the other leg, mark Codex unavailable |
| `===GEMINI_FALLBACK=== nokey / error` | Gemini skipped or failed | answer with Codex, mark it |
| `===FATAL===` | neither answered | do not synthesize; give the user the prompt in a code block to paste by hand |

`===CODEX_MODEL===` is read from the Codex session header — trust it over what a model says about itself.

## Step 5 — Show and select

```
Mode: solve
### Gemini (<GEMINI_MODEL>)
<text>
### Codex (<CODEX_MODEL>, subscription)
<text>
```

Then SELECT, not average: pick one answer and say why — "taking X because the checked fact Y beats argument Z". No majority vote, no blending; agreement between models counts less than it looks (their errors correlate). If no answer rests on a checked fact, return the fork to the user instead of a confident verdict.

- research: note where dates or numbers disagree; ask "Use these numbers?".
- review: list the P0/P1 findings, then 1–3 lines on which you accept and which you reject as false.
- audit: show the report, then offer to file backlog / knowledge / decision candidates — ask before writing anything.

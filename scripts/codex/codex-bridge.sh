#!/usr/bin/env bash
# codex-bridge.sh — read-only bridge from Claude Code to the Codex CLI.
#
# Codex always runs with -s read-only. Default auth is the ChatGPT subscription
# (`codex login`); --api switches to OPENAI_API_KEY taken from the environment.
# Keys are never read from files.
#
# Subcommands:
#   run       --prompt-file F [--proj DIR] [--search live|disabled] [--img P ...] [--api]
#   diff-risk [--proj DIR]                         risk of uncommitted changes, GO/NO-GO
#   audit     [--proj DIR] [--scope SCOPE]         whole-codebase audit
#   review    [--uncommitted|--base BR|--commit SHA] [--proj DIR]   native Codex review
#   followup  --question "..." [--proj DIR]        resume the last Codex session
# Common: --model M, --effort low|medium|high|xhigh|max|ultra
#
# Output contract (stdout):
#   ===CODEX_MODE=== / ===CODEX_MODEL=== / ===CODEX_EFFORT=== / ===CODEX_AUTH===
#   ===CODEX_CONFIDENCE=== / ===CODEX_GO_ALLOWED===   (structured modes)
#   ===CODEX_TEXT=== ... ===END_CODEX===
# On failure instead:
#   ===CODEX_FALLBACK=== noauth|quota|error   (+ ===CODEX_COOLDOWN=== seconds)
#   ===CODEX_ERR=== ... ===END_CODEX_ERR===
#   ===CODEX_RAW=== <path to raw stream>
#
# Env overrides:
#   AWK_CODEX_MODEL       model for run/diff-risk/followup
#   AWK_CODEX_MODEL_DEEP  model for audit/review
#   AWK_STATE_DIR         quota cooldown state (default ~/.claude/workflow-kit)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/redact.sh"
PROMPTS="$HERE/prompts"
SCHEMA="$PROMPTS/schema.json"
STATE_DIR="${AWK_STATE_DIR:-$HOME/.claude/workflow-kit}"
QUOTA_FILE="$STATE_DIR/codex-quota"
COOLDOWN=2700
RAW="$(mktemp "${TMPDIR:-/tmp}/codex-bridge.XXXXXX")"

# The model is always passed with -m: ~/.codex/config.toml is shared with the
# desktop app, which rewrites `model =` on update and breaks older CLIs.
policy_model() {
  case "$1" in
    audit|review) echo "${AWK_CODEX_MODEL_DEEP:-gpt-5.6-sol}" ;;
    *)            echo "${AWK_CODEX_MODEL:-gpt-5.6-terra}" ;;
  esac
}
policy_effort() {
  case "$1" in audit|review) echo high ;; *) echo medium ;; esac
}
valid_effort() {
  case "$1" in low|medium|high|xhigh|max|ultra) echo "$1" ;;
    *) echo "codex-bridge: unknown effort '$1', using medium" >&2; echo medium ;;
  esac
}

fail() {
  printf '===CODEX_FALLBACK=== error\n===CODEX_ERR===\n%s\n===END_CODEX_ERR===\n' "$1"
}

in_cooldown() {
  [ -f "$QUOTA_FILE" ] || return 1
  local last now left
  last=$(tr -dc '0-9' < "$QUOTA_FILE"); now=$(date +%s)
  left=$(( COOLDOWN - (now - ${last:-0}) ))
  [ "$left" -gt 0 ] || return 1
  printf '===CODEX_FALLBACK=== quota\n===CODEX_COOLDOWN=== %s\n' "$left"
  return 0
}

record_quota() {
  mkdir -p "$STATE_DIR" && date +%s > "$QUOTA_FILE"
}

# Empty answer = Codex did not work. Patterns are checked only then, so a review
# that talks about rate limits is not mistaken for a quota error.
classify_failure() {
  if grep -qiE 'not logged in|sign in with chatgpt|codex login|unauthori[sz]ed|invalid api key|\b401\b' "$RAW"; then
    printf '===CODEX_FALLBACK=== noauth\n'
  elif grep -qiE 'usage limit|rate limit|quota|too many requests|limit reached|\b429\b' "$RAW"; then
    printf '===CODEX_FALLBACK=== quota\n'
    record_quota
  else
    printf '===CODEX_FALLBACK=== error\n'
  fi
  printf '===CODEX_ERR===\n%s\n===END_CODEX_ERR===\n' "$(tail -n 6 "$RAW" | redact)"
  printf '===CODEX_RAW=== %s\n' "$RAW"
}

# Model and effort come from the session header, not from our variables:
# a model asked about itself can answer wrong, the header cannot.
header() { awk -F': ' -v k="$1" '$1==k{print $2; exit}' "$RAW"; }

# codex_exec <prompt_file> <proj> <auth> <effort> <search> <schema|"">
# Writes the final answer to stdout, returns 1 on empty answer.
codex_exec() {
  local pfile="$1" proj="$2" auth="$3" effort="$4" search="$5" schema="$6"
  local out; out=$(mktemp)
  local -a args=(exec -m "$MODEL" -c model_reasoning_effort="$effort"
    -c web_search="$search" -C "$proj" -s read-only --skip-git-repo-check)
  [ -n "$schema" ] && args+=(--output-schema "$schema")
  local img; for img in ${IMAGES[@]+"${IMAGES[@]}"}; do [ -f "$img" ] && args+=(-i "$img"); done
  # Prompt goes through stdin: with a non-TTY stdin codex waits for it anyway.
  if [ "$auth" = api ]; then
    [ -n "${OPENAI_API_KEY:-}" ] || { rm -f "$out"; echo "OPENAI_API_KEY is not set" > "$RAW"; return 1; }
    codex "${args[@]}" -o "$out" < "$pfile" > "$RAW" 2>&1
  else
    env -u OPENAI_API_KEY codex "${args[@]}" -c preferred_auth_method=chatgpt \
      -o "$out" < "$pfile" > "$RAW" 2>&1
  fi
  local text; text=$(cat "$out"); rm -f "$out"
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || return 1
  printf '%s' "$text"
}

# emit <mode> <auth> <text> [structured]
emit() {
  local mode="$1" auth="$2" text="$3" structured="${4:-}"
  local conf="n/a" go="n/a"
  if [ -n "$structured" ]; then
    local parsed
    parsed=$(printf '%s' "$text" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
c = str(d.get("confidence", "")).lower()
g = str(d.get("go_allowed", "")).lower()
a = d.get("analysis", "")
print(c if c in ("high", "medium", "low") else "low")
print(g if g in ("yes", "no", "n/a") else "n/a")
sys.stdout.write(a if isinstance(a, str) else json.dumps(a, ensure_ascii=False))
')
    if [ $? -eq 0 ]; then
      conf="${parsed%%$'\n'*}"; parsed="${parsed#*$'\n'}"
      go="${parsed%%$'\n'*}"; text="${parsed#*$'\n'}"
    else
      conf=low
    fi
  fi
  printf '===CODEX_MODE=== %s\n' "$mode"
  printf '===CODEX_MODEL=== %s\n' "$(header model)"
  printf '===CODEX_EFFORT=== %s\n' "$(header 'reasoning effort')"
  printf '===CODEX_AUTH=== %s\n' "$auth"
  printf '===CODEX_CONFIDENCE=== %s\n' "$conf"
  printf '===CODEX_GO_ALLOWED=== %s\n' "$go"
  printf '===CODEX_TEXT===\n%s\n===END_CODEX===\n' "$(printf '%s' "$text" | redact)"
  rm -f "$RAW"
}

# fill <template> KEY=file ...  — substitutes {{KEY}} with the file's contents
fill() {
  python3 - "$@" <<'PY'
import sys
tpl = open(sys.argv[1]).read()
for pair in sys.argv[2:]:
    key, path = pair.split("=", 1)
    tpl = tpl.replace("{{" + key + "}}", open(path).read())
sys.stdout.write(tpl)
PY
}

MODE="${1:-}"; [ $# -gt 0 ] && shift
PROJ="$(pwd)"; AUTH=chatgpt; EFFORT=""; MODEL=""; SEARCH=disabled
PFILE=""; SCOPE=general; QUESTION=""; SEL=(--uncommitted); IMAGES=()
while [ $# -gt 0 ]; do case "$1" in
  --img) IMAGES+=("$2"); shift 2;;
  --proj) PROJ="$2"; shift 2;;
  --prompt-file) PFILE="$2"; shift 2;;
  --search) SEARCH="$2"; shift 2;;
  --api) AUTH=api; shift;;
  --model) MODEL="$2"; shift 2;;
  --effort) EFFORT="$2"; shift 2;;
  --scope) SCOPE="$2"; shift 2;;
  --question) QUESTION="$2"; shift 2;;
  --uncommitted) SEL=(--uncommitted); shift;;
  --base) SEL=(--base "$2"); shift 2;;
  --commit) SEL=(--commit "$2"); shift 2;;
  *) echo "codex-bridge: unknown option $1" >&2; shift;;
esac; done
MODEL="${MODEL:-$(policy_model "$MODE")}"
EFFORT="$(valid_effort "${EFFORT:-$(policy_effort "$MODE")}")"
case "$SEARCH" in live|disabled|cached) ;; *) SEARCH=disabled;; esac

command -v codex >/dev/null 2>&1 || { fail "codex CLI not found. Install: npm install -g @openai/codex, then: codex login"; exit 0; }

case "$MODE" in
  run)
    [ -f "$PFILE" ] || { fail "no --prompt-file or file missing: $PFILE"; exit 0; }
    [ "$AUTH" = api ] || ! in_cooldown || exit 0
    if text=$(codex_exec "$PFILE" "$PROJ" "$AUTH" "$EFFORT" "$SEARCH" ""); then
      emit run "$AUTH" "$text"
    else
      classify_failure
    fi;;

  diff-risk)
    in_cooldown && exit 0
    d=$(mktemp)
    { git -C "$PROJ" diff 2>/dev/null
      staged=$(git -C "$PROJ" diff --staged 2>/dev/null)
      [ -n "$staged" ] && printf '\n--- STAGED ---\n%s\n' "$staged"
      # New files are not in git diff; pass names only, Codex reads them itself.
      untracked=$(git -C "$PROJ" ls-files -o --exclude-standard 2>/dev/null)
      [ -n "$untracked" ] && printf '\n--- UNTRACKED (read them yourself) ---\n%s\n' "$untracked"
    } > "$d"
    [ -s "$d" ] || echo "(no changes)" > "$d"
    p=$(mktemp); fill "$PROMPTS/diff-risk.txt" "GIT_DIFF=$d" > "$p"; rm -f "$d"
    if text=$(codex_exec "$p" "$PROJ" chatgpt "$EFFORT" disabled "$SCHEMA"); then
      rm -f "$p"; emit diff-risk chatgpt "$text" structured
    else
      rm -f "$p"; classify_failure
    fi;;

  audit)
    in_cooldown && exit 0
    case "$SCOPE" in
      auth)          hint="Focus: authentication, sessions, access control, token and cookie handling.";;
      env-deploy)    hint="Focus: environment variables, deploy scripts, configs, secrets hygiene.";;
      observability) hint="Focus: logging, alerts, monitoring, metrics, tracing.";;
      tests)         hint="Focus: test coverage and quality, missed edge cases, test configuration.";;
      architecture)  hint="Focus: project structure, dependencies, layering, coupling, tech debt.";;
      security)      hint="Focus: OWASP top 10, injection, XSS, CSRF, weak crypto, data leaks.";;
      *) SCOPE=general; hint="General audit: find P0/P1 risks in every area.";;
    esac
    s=$(mktemp); h=$(mktemp); p=$(mktemp)
    printf '%s' "$SCOPE" > "$s"; printf '%s' "$hint" > "$h"
    fill "$PROMPTS/audit.txt" "SCOPE=$s" "SCOPE_HINT=$h" > "$p"; rm -f "$s" "$h"
    if text=$(codex_exec "$p" "$PROJ" chatgpt "$EFFORT" disabled "$SCHEMA"); then
      rm -f "$p"; emit audit chatgpt "$text" structured
    else
      rm -f "$p"; classify_failure
    fi;;

  review)
    in_cooldown && exit 0
    # `codex exec review` takes no -C or -s: enter the project in a subshell and
    # force the sandbox through config, otherwise it falls back to config.toml.
    out=$(mktemp)
    ( cd "$PROJ" && env -u OPENAI_API_KEY codex exec review "${SEL[@]}" \
        --skip-git-repo-check -m "$MODEL" -c sandbox_mode=read-only \
        -c preferred_auth_method=chatgpt -c model_reasoning_effort="$EFFORT" \
        -o "$out" ) > "$RAW" 2>&1
    text=$(cat "$out"); rm -f "$out"
    if [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
      emit review chatgpt "$text"
    else
      classify_failure
    fi;;

  followup)
    [ -n "$QUESTION" ] || { fail 'followup needs --question "..."'; exit 0; }
    in_cooldown && exit 0
    # resume takes no -C/-s. --last picks the latest session of the current
    # directory, hence the cd; the sandbox is forced through config.
    out=$(mktemp)
    ( cd "$PROJ" && printf '%s' "$QUESTION" | env -u OPENAI_API_KEY codex exec resume --last \
        --skip-git-repo-check -m "$MODEL" -c preferred_auth_method=chatgpt -c sandbox_mode=read-only \
        -c model_reasoning_effort="$EFFORT" -o "$out" - ) > "$RAW" 2>&1
    text=$(cat "$out"); rm -f "$out"
    if [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
      emit followup chatgpt "$text"
    else
      classify_failure
    fi;;

  record-quota) record_quota; rm -f "$RAW";;

  *)
    rm -f "$RAW"
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2;;
esac

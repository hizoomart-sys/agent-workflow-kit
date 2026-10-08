#!/usr/bin/env bash
# ask-models.sh — asks two outside models the same question in parallel.
#
#   solve    --gemini-prompt F --gpt-prompt F [--img P ...]   no web search
#   research --prompt F [--img P ...]                          with web search
#
# Gemini leg: Google Gemini API, key from GEMINI_API_KEY in the environment.
#   No key → the leg is skipped (===GEMINI_FALLBACK=== nokey), Codex answers alone.
#   Model: AWK_GEMINI_MODEL, default gemini-pro-latest.
# GPT leg: Codex CLI through codex-bridge.sh (ChatGPT subscription, read-only).
# Keys are never read from files.
#
# Output (stdout):
#   ===GEMINI_MODEL=== / ===GEMINI_TEXT=== ... ===END_GEMINI===
#     or ===GEMINI_FALLBACK=== nokey|error + ===GEMINI_ERR=== ... ===END_GEMINI_ERR===
#   the codex-bridge block (===CODEX_TEXT=== or ===CODEX_FALLBACK===)
#   ===FATAL=== when neither leg answered
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/redact.sh"
BRIDGE="$HERE/../codex/codex-bridge.sh"
GEMINI_MODEL="${AWK_GEMINI_MODEL:-gemini-pro-latest}"
GEMINI_URL="${AWK_GEMINI_URL:-https://generativelanguage.googleapis.com/v1beta/models}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ask-models.XXXXXX")"

# gemini_body <prompt_file> <search:yes|no> [images...]
gemini_body() {
  local pfile="$1" search="$2"; shift 2
  local parts img mime
  parts=$(jq -n --rawfile t "$pfile" '[{text:$t}]')
  for img in "$@"; do
    [ -f "$img" ] || { echo "ask-models: skip missing image $img" >&2; continue; }
    mime=$(file -b --mime-type "$img")
    parts=$(printf '%s' "$parts" | jq --arg m "$mime" --rawfile d <(base64 < "$img" | tr -d '\n') \
      '. + [{inline_data:{mime_type:$m, data:$d}}]')
  done
  if [ "$search" = yes ]; then
    jq -n --argjson p "$parts" '{contents:[{role:"user",parts:$p}], tools:[{google_search:{}}]}'
  else
    jq -n --argjson p "$parts" '{contents:[{role:"user",parts:$p}]}'
  fi
}

# gemini_leg <body_file> — writes $WORK/gemini.json, retries twice on failure
gemini_leg() {
  [ -n "${GEMINI_API_KEY:-}" ] || return 0
  # The key goes in a header file, not argv: argv is visible to other processes.
  ( umask 077; printf 'x-goog-api-key: %s\n' "$GEMINI_API_KEY" > "$WORK/headers" )
  local attempt
  for attempt in 1 2 3; do
    # Truncate before each try: on a dropped connection curl may leave the
    # previous response in place, and it would pass as a fresh answer.
    : > "$WORK/gemini.json"
    curl -sS --max-time 300 -X POST "$GEMINI_URL/$GEMINI_MODEL:generateContent" \
      -H @"$WORK/headers" -H "Content-Type: application/json" \
      --data-binary @"$1" -o "$WORK/gemini.json" 2> "$WORK/gemini.err" \
      && [ -n "$(gemini_text)" ] && return 0
    [ "$attempt" -lt 3 ] && sleep 2
  done
  return 1
}

gemini_text() {
  jq -r '[.candidates[0].content.parts[]?.text // empty] | join("")' "$WORK/gemini.json" 2>/dev/null
}

emit_gemini() {
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    printf '===GEMINI_FALLBACK=== nokey\n'
    return 1
  fi
  local text; text=$(gemini_text)
  if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
    printf '===GEMINI_FALLBACK=== error\n===GEMINI_ERR===\n%s\n===END_GEMINI_ERR===\n' \
      "$( { jq -r '.error.message // empty' "$WORK/gemini.json" 2>/dev/null; cat "$WORK/gemini.err" 2>/dev/null; } | head -c 600 | redact)"
    return 1
  fi
  printf '===GEMINI_MODEL=== %s\n' "$(jq -r '.modelVersion // empty' "$WORK/gemini.json")"
  local sources
  sources=$(jq -r '[.candidates[0].groundingMetadata.groundingChunks[]?.web.uri // empty] | length' "$WORK/gemini.json" 2>/dev/null)
  [ "${sources:-0}" -gt 0 ] && printf '===GEMINI_SOURCES=== %s\n' "$sources"
  printf '===GEMINI_TEXT===\n%s\n===END_GEMINI===\n' "$(printf '%s' "$text" | redact)"
}

# run_pair <gemini_prompt> <gpt_prompt> <search:yes|no> <codex_dir> [images...]
run_pair() {
  local gp="$1" pp="$2" search="$3" dir="$4"; shift 4
  local -a imgargs=(); local img
  for img in "$@"; do imgargs+=(--img "$img"); done
  gemini_body "$gp" "$search" "$@" > "$WORK/body.json"
  gemini_leg "$WORK/body.json" &
  local codex_search=disabled; [ "$search" = yes ] && codex_search=live
  "$BRIDGE" run --prompt-file "$pp" --proj "$dir" --search "$codex_search" \
    ${imgargs[@]+"${imgargs[@]}"} > "$WORK/codex.out" &
  wait
  local g_ok=1 c_ok=1
  emit_gemini || g_ok=0
  cat "$WORK/codex.out"
  grep -q '^===CODEX_TEXT===' "$WORK/codex.out" || c_ok=0
  [ $g_ok -eq 0 ] && [ $c_ok -eq 0 ] && printf '===FATAL=== neither model answered\n'
  rm -rf "$WORK"
}

check_deps() {
  local d; for d in jq curl; do
    command -v "$d" >/dev/null 2>&1 || { echo "ask-models: $d is required" >&2; exit 2; }
  done
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
GP=""; PP=""; IMAGES=()
while [ $# -gt 0 ]; do case "$1" in
  --gemini-prompt) GP="$2"; shift 2;;
  --gpt-prompt) PP="$2"; shift 2;;
  --prompt) GP="$2"; PP="$2"; shift 2;;
  --img) IMAGES+=("$2"); shift 2;;
  *) echo "ask-models: unknown option $1" >&2; shift;;
esac; done

case "$CMD" in
  solve)
    check_deps
    [ -f "$GP" ] && [ -f "$PP" ] || { echo "solve needs --gemini-prompt F --gpt-prompt F" >&2; exit 2; }
    # Codex reads the current project (read-only) to ground its answer.
    run_pair "$GP" "$PP" no "$(pwd)" ${IMAGES[@]+"${IMAGES[@]}"};;
  research)
    check_deps
    [ -f "$GP" ] || { echo "research needs --prompt F" >&2; exit 2; }
    # Research needs the web, not the code: Codex runs in an empty directory.
    run_pair "$GP" "$PP" yes "$WORK" ${IMAGES[@]+"${IMAGES[@]}"};;
  *)
    rm -rf "$WORK"
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2;;
esac

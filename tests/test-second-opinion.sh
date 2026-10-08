#!/usr/bin/env bash
# Offline tests for codex-bridge.sh and ask-models.sh: fake codex and curl on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BRIDGE="$ROOT/scripts/codex/codex-bridge.sh"
ASK="$ROOT/scripts/models/ask-models.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export AWK_STATE_DIR="$T/state" FAKE_LOG="$T/args.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY:-unset}" >> "$FAKE_LOG"
out=""; prev=""; model=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-m" ] && model="$a"
  prev="$a"
done
cat > /dev/null
echo "model: ${model:-default}"
echo "reasoning effort: medium"
case "${FAKE_CODEX:-ok}" in
  ok)      echo "answer sk-abcdefghijklmnop" > "$out";;
  json)    echo '{"confidence":"high","go_allowed":"no","analysis":"Verdict: NO-GO"}' > "$out";;
  noauth)  echo "Error: Not logged in. Run codex login"; exit 1;;
  quota)   echo "ERROR: usage limit reached, try again later"; exit 1;;
  crash)   echo "panic: something else"; exit 1;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-H" ] && [ "${a#@}" != "$a" ] && cat "${a#@}" >> "$FAKE_LOG"
  prev="$a"
done
cp "$FAKE_GEMINI" "$out"
EOF
chmod +x "$T/bin/codex" "$T/bin/curl"
export PATH="$T/bin:$PATH"
echo "question" > "$T/p.txt"

# 1. run: read-only sandbox, explicit model, subscription auth, redacted answer
export OPENAI_API_KEY=sk-should-not-leak-1234
out=$(FAKE_CODEX=ok "$BRIDGE" run --prompt-file "$T/p.txt" --proj "$T")
has "$out" "===CODEX_TEXT===" && ok || bad "run: no CODEX_TEXT"
has "$out" "***REDACTED***" && ok || bad "run: key in answer not redacted"
has "$out" "===CODEX_MODEL=== gpt-5.6-terra" && ok || bad "run: model not taken from header"
grep -q -- "-s read-only" "$FAKE_LOG" && ok || bad "run: no read-only sandbox"
grep -q "OPENAI_API_KEY=unset" "$FAKE_LOG" && ok || bad "run: API key leaked into subscription call"

# 2. --api uses the env key, and fails cleanly without it
: > "$FAKE_LOG"
FAKE_CODEX=ok "$BRIDGE" run --prompt-file "$T/p.txt" --api > /dev/null
grep -q "OPENAI_API_KEY=sk-should-not-leak-1234" "$FAKE_LOG" && ok || bad "api: env key not passed"
out=$(env -u OPENAI_API_KEY FAKE_CODEX=ok "$BRIDGE" run --prompt-file "$T/p.txt" --api)
has "$out" "===CODEX_FALLBACK=== error" && has "$out" "OPENAI_API_KEY is not set" && ok || bad "api: missing key not reported"
unset OPENAI_API_KEY

# 3. failure classes
out=$(FAKE_CODEX=noauth "$BRIDGE" run --prompt-file "$T/p.txt")
has "$out" "===CODEX_FALLBACK=== noauth" && ok || bad "noauth not classified"
out=$(FAKE_CODEX=crash "$BRIDGE" run --prompt-file "$T/p.txt")
has "$out" "===CODEX_FALLBACK=== error" && ok || bad "crash not classified as error"
out=$(FAKE_CODEX=quota "$BRIDGE" run --prompt-file "$T/p.txt")
has "$out" "===CODEX_FALLBACK=== quota" && ok || bad "quota not classified"

# 4. quota cooldown short-circuits the next call without starting codex
: > "$FAKE_LOG"
out=$(FAKE_CODEX=ok "$BRIDGE" diff-risk --proj "$T")
has "$out" "===CODEX_COOLDOWN===" && ok || bad "cooldown not applied"
[ ! -s "$FAKE_LOG" ] && ok || bad "codex started during cooldown"
rm -f "$T/state/codex-quota"

# 5. structured mode: JSON parsed into confidence / go_allowed, deep model for audit
git -C "$T" init -q && echo x > "$T/new.txt"
out=$(FAKE_CODEX=json "$BRIDGE" diff-risk --proj "$T")
has "$out" "===CODEX_GO_ALLOWED=== no" && has "$out" "===CODEX_CONFIDENCE=== high" && ok || bad "diff-risk JSON not parsed"
has "$out" "Verdict: NO-GO" && ok || bad "diff-risk analysis missing"
out=$(FAKE_CODEX=json "$BRIDGE" audit --proj "$T" --scope security)
has "$out" "===CODEX_MODEL=== gpt-5.6-sol" && ok || bad "audit: deep model not used"
out=$(FAKE_CODEX=json AWK_CODEX_MODEL_DEEP=my-model "$BRIDGE" audit --proj "$T")
has "$out" "===CODEX_MODEL=== my-model" && ok || bad "audit: model override ignored"

# 6. ask-models without GEMINI_API_KEY: Codex alone, Gemini reported as nokey
echo '{"candidates":[{"content":{"parts":[{"text":"gemini says hi"}]}}],"modelVersion":"gemini-test"}' > "$T/g.json"
export FAKE_GEMINI="$T/g.json"
: > "$FAKE_LOG"
out=$(cd "$T" && env -u GEMINI_API_KEY FAKE_CODEX=ok "$ASK" solve --gemini-prompt "$T/p.txt" --gpt-prompt "$T/p.txt")
has "$out" "===GEMINI_FALLBACK=== nokey" && ok || bad "no key: Gemini not reported as nokey"
has "$out" "===CODEX_TEXT===" && ok || bad "no key: Codex leg missing"
grep -q "^curl" "$FAKE_LOG" && bad "no key: curl was called" || ok

# 7. ask-models with key: both legs, key sent as header, search tool on research
export GEMINI_API_KEY=test-gemini-key
: > "$FAKE_LOG"
out=$(cd "$T" && FAKE_CODEX=ok "$ASK" research --prompt "$T/p.txt")
has "$out" "gemini says hi" && has "$out" "===GEMINI_MODEL=== gemini-test" && ok || bad "Gemini answer not parsed"
grep -q "x-goog-api-key: test-gemini-key" "$FAKE_LOG" && ok || bad "Gemini key not sent as header"
grep -q "web_search=live" "$FAKE_LOG" && ok || bad "research: Codex web search off"
grep "^curl " "$FAKE_LOG" | grep -q "test-gemini-key" && bad "Gemini key on curl argv" || ok

# 8. both legs down → FATAL
echo '{"error":{"message":"API key not valid"}}' > "$T/g.json"
out=$(cd "$T" && FAKE_CODEX=crash "$ASK" solve --gemini-prompt "$T/p.txt" --gpt-prompt "$T/p.txt")
has "$out" "===FATAL===" && ok || bad "FATAL not printed"
has "$out" "API key not valid" && ok || bad "Gemini error not surfaced"

# 8b. review and followup force the read-only sandbox
: > "$FAKE_LOG"
out=$(FAKE_CODEX=ok "$BRIDGE" review --proj "$T")
has "$out" "===CODEX_TEXT===" && ok || bad "review: no CODEX_TEXT"
[ "$(grep -c 'sandbox_mode=read-only' "$FAKE_LOG")" -ge 1 ] && ok || bad "review: no read-only sandbox"
: > "$FAKE_LOG"
out=$(FAKE_CODEX=ok "$BRIDGE" followup --question q --proj "$T")
has "$out" "===CODEX_TEXT===" && ok || bad "followup: no CODEX_TEXT"
[ "$(grep -c 'sandbox_mode=read-only' "$FAKE_LOG")" -ge 1 ] && ok || bad "followup: no read-only sandbox"

# 8c. followup passes the model explicitly (config.toml is rewritten by the desktop app)
: > "$FAKE_LOG"
FAKE_CODEX=ok "$BRIDGE" followup --question q --proj "$T" > /dev/null
grep -q -- "resume --last.*-m gpt-5.6-terra" "$FAKE_LOG" && ok || bad "followup: model not passed"

# 9. no secrets read from files
if grep -nE '\.env\b|grep [A-Z_]*KEY' "$BRIDGE" "$ASK"; then bad "scripts read keys from files"; else ok; fi

echo "second-opinion: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

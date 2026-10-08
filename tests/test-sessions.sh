#!/usr/bin/env bash
# Tests for module "sessions": save-session.py, session-resume.sh, precompact-fallback.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts/session"
SAVE="$S/save-session.py"
RESUME="$S/session-resume.sh"
PRECOMPACT="$S/precompact-fallback.sh"
MARKER='⟦save-session: конец вывода — ничего больше не печатать⟧'

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <condition-exit-code>
    if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AWK_FALLBACK_DIR="$TMP/fallback"
unset CLAUDE_CODE_SESSION_ID

REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git config user.email t@example.com
git config user.name t
echo hi > a.txt
git add a.txt
git commit -q -m init

PD="$REPO/.planning/sessions/test123"
BODY="$TMP/body.md"
cat > "$BODY" <<'EOF'
- Done: wrote the module
- Not done: tests for edge cases
- Next: run scripts/foo.py:42 with --verbose
- Waiting on user:
- Files:
  - /tmp/example/a.txt (main file)
EOF

# --dry-run writes nothing
OUT="$(python3 "$SAVE" "Test session" --sid test123 --dry-run < "$BODY" 2>&1)"
check "dry-run exits 0" $?
[ ! -f "$PD"/RESUME.md ]; check "dry-run does not write RESUME.md" $?
echo "$OUT" | grep -qF "$MARKER"; check "dry-run prints marker" $?

# real save
OUT="$(python3 "$SAVE" "Test session" --sid test123 < "$BODY" 2>&1)"
check "save exits 0" $?
[ -f "$PD"/CONTEXT.md ]; check "CONTEXT.md exists" $?
[ -f "$PD"/RESUME.md ]; check "RESUME.md exists" $?
echo "$OUT" | grep -qF "$MARKER"; check "marker printed" $?
echo "$OUT" | grep -q '^продолжаем Test session'; check "fence 'продолжаем <topic>' printed" $?
grep -q '^status: in_progress' "$PD"/RESUME.md; check "RESUME status: in_progress" $?
grep -q '^next: run scripts/foo.py:42' "$PD"/RESUME.md; check "RESUME next key" $?
grep -q '^session_id: test123' "$PD"/RESUME.md; check "RESUME session_id key" $?
grep -q '^- Следующий шаг: run scripts/foo.py:42' "$PD"/CONTEXT.md; check "EN alias canonicalized in CONTEXT.md" $?

# --complete refusal barrier: empty Next + Waiting -> exit 4, nothing written
printf -- '- Done: only this\n' > "$TMP/empty.md"
cp "$PD"/RESUME.md "$TMP/resume.before"
python3 "$SAVE" "Refused" --sid test123 < "$TMP/empty.md" > /dev/null 2>&1
RC=$?
[ "$RC" -eq 4 ]; check "empty tail without --complete exits 4 (got $RC)" $?
cmp -s "$PD"/RESUME.md "$TMP/resume.before"; check "refusal leaves RESUME.md untouched" $?

# Waiting only -> waiting_user
printf -- '- Done: x\n- Waiting on user: approve the plan\n' > "$TMP/wait.md"
python3 "$SAVE" "Waiting session" --sid test123 < "$TMP/wait.md" > /dev/null 2>&1
grep -q '^status: waiting_user' "$PD"/RESUME.md; check "waiting_user status" $?
grep -q '^human_pending: approve the plan' "$PD"/RESUME.md; check "human_pending key" $?

# restore in_progress card for the resume test
python3 "$SAVE" "Test session" --sid test123 < "$BODY" > /dev/null 2>&1

# SessionStart hook: clear -> additionalContext contains the next step
HOOK_OUT="$(printf '{"source":"clear","session_id":"test123"}' | bash "$RESUME")"
echo "$HOOK_OUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SessionStart"
assert "run scripts/foo.py:42" in h["additionalContext"]
'
check "resume hook (clear) injects next step" $?

# source=resume -> {}
HOOK_OUT="$(printf '{"source":"resume","session_id":"test123"}' | bash "$RESUME")"
[ "$HOOK_OUT" = "{}" ]; check "resume hook (resume) outputs {}" $?

# startup: own session-scoped RESUME is injected, a foreign sid gets {}
HOOK_OUT="$(printf '{"source":"startup","session_id":"test123"}' | bash "$RESUME")"
echo "$HOOK_OUT" | grep -q 'run scripts/foo.py:42'; check "resume hook (startup, own RESUME) injects" $?
HOOK_OUT="$(printf '{"source":"startup","session_id":"other999"}' | bash "$RESUME")"
[ "$HOOK_OUT" = "{}" ]; check "resume hook (startup, foreign sid) outputs {}" $?

# precompact: new transcript format {type, message:{content}}
TR="$TMP/transcript.jsonl"
cat > "$TR" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello there"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"},{"type":"tool_use","name":"Bash"}]}}
EOF
PC_OUT="$(printf '{"transcript_path":"%s","trigger":"auto","session_id":"test123"}' "$TR" | bash "$PRECOMPACT")"
[ "$PC_OUT" = "{}" ]; check "precompact outputs {}" $?
grep -q '^\[user\] hello there' "$PD"/RESUME.md; check "precompact parses user line" $?
grep -q '^\[assistant\] working on it | \[tool:Bash\]' "$PD"/RESUME.md; check "precompact parses assistant line" $?

# precompact: secrets must not reach RESUME.md (tool_result dropped, user text masked)
TR2="$TMP/transcript-secret.jsonl"
cat > "$TR2" <<'EOF'
{"type":"user","message":{"role":"user","content":"my token: ghp_SECRETUSERTOKEN123"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"OPENAI_API_KEY=sk-abcSECRET123456789"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok, key AKIAABCDEFGHIJKLMNOP seen"}]}}
EOF
printf '{"transcript_path":"%s","trigger":"auto","session_id":"test123"}' "$TR2" | bash "$PRECOMPACT" >/dev/null
grep -q 'SECRETUSERTOKEN123' "$PD"/RESUME.md; [ $? -ne 0 ]; check "precompact masks user-message secret" $?
grep -q 'sk-abcSECRET' "$PD"/RESUME.md; [ $? -ne 0 ]; check "precompact drops tool_result secret" $?
grep -q 'AKIAABCDEFGHIJKLMNOP' "$PD"/RESUME.md; [ $? -ne 0 ]; check "precompact masks AWS key" $?
grep -q '\[tool_result\]' "$PD"/RESUME.md; check "precompact keeps tool_result marker" $?

# explicit --complete: allowed, no fence
OUT="$(python3 "$SAVE" "Closed" --sid test123 --complete < "$TMP/empty.md" 2>&1)"
check "--complete exits 0" $?
grep -q '^status: complete' "$PD"/RESUME.md; check "status: complete" $?
echo "$OUT" | grep -q '^продолжаем'; [ $? -ne 0 ]; check "no fence on complete" $?

# syntax checks
for f in "$S"/*.sh "$HERE/test-sessions.sh"; do bash -n "$f"; check "bash -n $(basename "$f")" $?; done
python3 -m py_compile "$SAVE"; check "py_compile save-session.py" $?
find "$S" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null

echo
if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "all tests passed"

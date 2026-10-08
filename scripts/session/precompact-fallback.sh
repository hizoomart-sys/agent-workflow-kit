#!/usr/bin/env bash
# precompact-fallback.sh — PreCompact hook.
# Детерминированный фолбэк: хвост транскрипта + git status + cwd дописываются в RESUME.md.
# Не блокирует compact (никакого "decision":"block"). Без LLM-вызовов.
#
# Input (stdin): JSON с "transcript_path", "trigger" (manual|auto), "session_id".

set -euo pipefail

INPUT="$(cat)"

PARSED="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('transcript_path', ''))
print(d.get('trigger', 'unknown'))
print(d.get('session_id', ''))
" 2>/dev/null || true)"
TRANSCRIPT_PATH="$(printf '%s\n' "$PARSED" | sed -n 1p)"
TRIGGER="$(printf '%s\n' "$PARSED" | sed -n 2p)"
HOOK_SID="$(printf '%s\n' "$PARSED" | sed -n 3p)"
[[ -n "$HOOK_SID" ]] && export CLAUDE_CODE_SESSION_ID="$HOOK_SID"
TRIGGER="${TRIGGER:-unknown}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$HERE/session-resolve.sh"
FALLBACK="${AWK_FALLBACK_DIR:-${HOME}/.claude/workflow-kit/sessions/.planning}"

# Walk-up, если резолвер недоступен.
find_planning_legacy() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.planning" ]]; then
            echo "$dir/.planning"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    mkdir -p "$FALLBACK"
    echo "$FALLBACK"
}

# precompact ПИШЕТ в RESUME → писать в session-scoped dir, не в общий корневой.
PLANNING_DIR=""
if [[ -f "$RESOLVER" ]]; then
    PLANNING_DIR="$(bash "$RESOLVER" planning --cwd "$PWD" 2>/dev/null || true)"
fi
[[ -z "$PLANNING_DIR" ]] && PLANNING_DIR="$(find_planning_legacy)"
mkdir -p "$PLANNING_DIR" 2>/dev/null || true
RESUME_PATH="${PLANNING_DIR}/RESUME.md"

{
    echo ""
    echo "--- precompact-fallback (trigger: ${TRIGGER}, $(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
    echo "cwd: ${PWD}"
    echo ""

    if git -C "$PWD" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        echo "git_status:"
        git -C "$PWD" status --short 2>/dev/null | head -20 || true
        echo "last_commits:"
        git -C "$PWD" log --oneline -5 2>/dev/null || true
    else
        echo "git: not a repo"
    fi
    echo ""

    # Хвост транскрипта — последние 30 user/assistant событий.
    # Формат строк JSONL: {"type": "user"|"assistant", "message": {"content": ...}}
    if [[ -f "$TRANSCRIPT_PATH" ]]; then
        echo "transcript_tail (last 30 events):"
        python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import sys, json, re

SECRET_RES = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", re.S),
    re.compile(r"sk-[A-Za-z0-9_\-]{6,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{3,}"),
    re.compile(r"xox[bp]-[A-Za-z0-9\-]+"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"(api[_-]?key|token|secret|password)\s*[:=]\s*\S+", re.I),
]

def mask(text):
    for rx in SECRET_RES:
        text = rx.sub("***", text)
    return text

events = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") in ("user", "assistant") and isinstance(obj.get("message"), dict):
            events.append(obj)

for ev in events[-30:]:
    role = ev["type"]
    content = ev["message"].get("content", "")
    if isinstance(content, list):
        parts = []
        for c in content:
            if not isinstance(c, dict):
                parts.append(mask(str(c))[:300])
                continue
            t = c.get("type", "")
            if t == "text":
                parts.append(mask(c.get("text", ""))[:300])
            elif t == "tool_use":
                parts.append(f"[tool:{c.get('name', '')}]")
            elif t == "tool_result":
                parts.append("[tool_result]")
        content = " | ".join(parts)
    else:
        content = mask(str(content))
    print(f"[{role}] {content[:400]}")
PYEOF
    fi
    echo "--- end precompact-fallback ---"
} >> "$RESUME_PATH" 2>/dev/null || true

echo "{}"

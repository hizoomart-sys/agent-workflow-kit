#!/usr/bin/env bash
# session-resume.sh — SessionStart hook.
# Читает RESUME.md из .planning/ и инжектит императив, чтобы ассистент продолжил работу
# сразу, не спрашивая «что делать?».
#
# Input (stdin): JSON {"source": startup|resume|clear|compact, "session_id": "..."}
# Output: JSON {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ...}}
#         либо "{}" когда инжектить нечего.

set -euo pipefail

INPUT="$(cat)"
PARSED="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('source') or d.get('trigger', ''))
print(d.get('session_id', ''))
" 2>/dev/null || true)"
TRIGGER="$(printf '%s\n' "$PARSED" | sed -n 1p)"
HOOK_SID="$(printf '%s\n' "$PARSED" | sed -n 2p)"
[[ -n "$HOOK_SID" ]] && export CLAUDE_CODE_SESSION_ID="$HOOK_SID"

# Политика по триггеру:
#   clear/compact — контекст потерян → полноценный resume (включая корневой RESUME в main).
#   startup       — только СВОЙ session-scoped RESUME или AMBIGUOUS-warning; голый корневой
#                   не подставляем (свежее окно ведёт человек через «продолжаем»).
STARTUP_ONLY_OWN=0
case "$TRIGGER" in
    clear|compact) ;;
    startup)       STARTUP_ONLY_OWN=1 ;;
    *)             echo "{}"; exit 0 ;;
esac

emit() {
    python3 -c "
import json, sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.stdin.read()}}))
" <<< "$1"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$HERE/session-resolve.sh"
FALLBACK="${AWK_FALLBACK_DIR:-${HOME}/.claude/workflow-kit/sessions/.planning}"

find_resume_legacy() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.planning/RESUME.md" ]]; then
            echo "$dir/.planning/RESUME.md"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    if [[ -f "$FALLBACK/RESUME.md" ]]; then
        echo "$FALLBACK/RESUME.md"
        return 0
    fi
    return 1
}

RESOLVER_OUT=""
if [[ -f "$RESOLVER" ]]; then
    RESOLVER_OUT="$(bash "$RESOLVER" resume 2>/dev/null || true)"
fi

# fail-closed: в сессионном контексте без своего RESUME и при чужом корневом резолвер
# печатает SESSION_RESUME_AMBIGUOUS. Чужой корневой не подставляем — только предупреждение.
if [[ "$RESOLVER_OUT" == "SESSION_RESUME_AMBIGUOUS" ]]; then
    CUR_BRANCH="$(git -C "$PWD" branch --show-current 2>/dev/null || echo '?')"
    WARN="[SESSION RESUMED after ${TRIGGER}] — RESUME NOT FOUND for this session.
The current session (branch ${CUR_BRANCH}) has no RESUME of its own, and the root
.planning/RESUME.md belongs to ANOTHER session. Do NOT continue from the root RESUME.

Before acting:
1. git worktree list  +  git log --oneline -15 --all
   — find out what work was actually done on this branch.
2. Check this branch's own .planning/ (if any), not the root RESUME.
3. Ask the user \"what are we continuing?\" if the branch context is unclear."
    emit "$WARN"
    exit 0
fi

RESUME_PATH="$RESOLVER_OUT"
[[ -z "${RESUME_PATH:-}" ]] && RESUME_PATH="$(find_resume_legacy 2>/dev/null || true)"

# startup-гейт: только свой session-scoped RESUME (путь содержит /sessions/).
if [[ "$STARTUP_ONLY_OWN" == "1" && "$RESUME_PATH" != *"/sessions/"* ]]; then
    echo "{}"
    exit 0
fi

if [[ -z "$RESUME_PATH" || ! -f "$RESUME_PATH" ]]; then
    echo "{}"
    exit 0
fi

RESUME_CONTENT="$(cat "$RESUME_PATH")"

# `|| true`: grep без матча под pipefail иначе роняет всю подстановку.
WHERE="$(echo "$RESUME_CONTENT" | grep '^where:' | sed 's/^where: *//' | head -1 || true)"
STATUS="$(echo "$RESUME_CONTENT" | grep '^status:' | sed 's/^status: *//' | head -1 || true)"
NEXT="$(echo "$RESUME_CONTENT" | grep '^next:' | sed 's/^next: *//' | head -1 || true)"
BLOCKERS="$(echo "$RESUME_CONTENT" | grep '^blockers:' | sed 's/^blockers: *//' | head -1 || true)"
HUMAN_PENDING="$(echo "$RESUME_CONTENT" | grep '^human_pending:' | sed 's/^human_pending: *//' | head -1 || true)"

IMPERATIVE="[SESSION RESUMED after ${TRIGGER}]
RESUME.md found. Do NOT ask what to do — continue immediately.

Session: ${WHERE:-unknown}
Status: ${STATUS:-in_progress}
Next step: ${NEXT:--}
Blockers: ${BLOCKERS:--}
$([ -n "$HUMAN_PENDING" ] && echo "Waiting on user: ${HUMAN_PENDING}" || true)

Full RESUME.md:
${RESUME_CONTENT}

Resume now. First line of your response should confirm the next step you are continuing."

emit "$IMPERATIVE"

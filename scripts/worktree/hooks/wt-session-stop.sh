#!/usr/bin/env bash
# wt-session-stop.sh — Stop hook. Если текущая ветка — сессионная (<prefix>/<sid>) и в ней
# есть невлитая работа, печатает предложение слить её (wt merge). Сам ничего не мержит.
# Срабатывает один раз на состояние ветки (HEAD + признак грязного дерева), чтобы не шуметь
# на каждом ходе.
#
# Вход (stdin): JSON {"session_id": "...", "cwd": "..."}.
# Тихий выход 0: не git-репозиторий, enabled != true, не сессионная ветка, нечего сливать.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_SCRIPTS="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../wt-lib.sh
source "$WT_SCRIPTS/wt-lib.sh" 2>/dev/null || exit 0

INPUT=""
[ -t 0 ] || INPUT="$(cat 2>/dev/null || true)"
if [ -n "$INPUT" ]; then
    PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("session_id", "") or "")
print(d.get("cwd", "") or "")
' 2>/dev/null || true)"
    HOOK_SID="$(printf '%s\n' "$PARSED" | sed -n 1p)"
    HOOK_CWD="$(printf '%s\n' "$PARSED" | sed -n 2p)"
    [ -n "$HOOK_SID" ] && export CLAUDE_CODE_SESSION_ID="$HOOK_SID"
    [ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ] && cd "$HOOK_CWD" 2>/dev/null
fi

REPO_ROOT="$(wt_find_repo_root "$PWD" 2>/dev/null)" || exit 0
wt_load_config "$REPO_ROOT"
[ "$WT_ENABLED" = "true" ] || exit 0

BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
case "$BRANCH" in
    "$WT_PREFIX"/?*) ;;
    *) exit 0 ;;
esac
SID="${BRANCH#"$WT_PREFIX"/}"

CATEGORY="$(wt_classify_branch "$REPO_ROOT" "$BRANCH" "$WT_BASE" 2>/dev/null || echo UNKNOWN)"
case "$CATEGORY" in
    HAS_UNIQUE|ACTIVE_CLEAN|ACTIVE_DIRTY) ;;
    *) exit 0 ;;
esac

# Один раз на состояние: тот же HEAD и то же «грязно/чисто» → молчим
STATE="$(git rev-parse HEAD 2>/dev/null)-$CATEGORY"
MARK="$WORKFLOW_KIT_HOME/run/wt-stop-$SID"
if [ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$STATE" ]; then
    exit 0
fi
mkdir -p "$WORKFLOW_KIT_HOME/run" 2>/dev/null && printf '%s' "$STATE" >"$MARK" 2>/dev/null

FILES="$(git diff --name-only "${WT_BASE}...${BRANCH}" 2>/dev/null | head -5 | tr '\n' ',' | sed 's/,$//')"
[ -n "$FILES" ] || FILES="(нет коммитов, только незакоммиченные правки)"

MSG="Сессия ${SID} завершается с невлитой работой (${CATEGORY}). Ветка ${BRANCH}, файлы: ${FILES}. Предложи оператору ОДИН выбор: влить в ${WT_BASE} (bash \"$WT_SCRIPTS/wt\" merge ${SID}; при незакоммиченных файлах сначала закоммитить свои) / оставить ветку / выбросить (wt merge ${SID} --cleanup-only --force). Не сливай без ответа: это изменение общей истории."

python3 -c '
import json, sys
print(json.dumps({"systemMessage": sys.argv[1], "additionalContext": sys.argv[1]}))
' "$MSG" 2>/dev/null
exit 0

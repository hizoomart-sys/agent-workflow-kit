#!/usr/bin/env bash
# wt-session-start.sh — SessionStart hook модуля «параллельные сессии».
#  1) фоновая уборка хвостов (wt-doctor --gc: только локальные ветки без worktree, с backup-ref);
#  2) если сессия стартовала в ГЛАВНОМ checkout — инжект указания создать worktree.
#
# Вход (stdin): JSON {"session_id": "...", "cwd": "..."}.
# Тихий выход 0: не git-репозиторий, нет конфига, enabled != true, любая ошибка.

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

# ─── 1. Фоновый GC ───────────────────────────────────────────────────────────
# Лог и маркер сбоя — в домашнем каталоге кита, не в репозитории.
KEY="$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)"
GC_LOG="$WORKFLOW_KIT_HOME/logs/wt-gc-$KEY.log"
GC_FAIL="$WORKFLOW_KIT_HOME/run/wt-gc-failed-$KEY"
mkdir -p "$WORKFLOW_KIT_HOME/logs" "$WORKFLOW_KIT_HOME/run" 2>/dev/null || true

GC_FAIL_MSG=""
if [ -f "$GC_FAIL" ]; then
    GC_FAIL_MSG="Фоновая уборка worktree (wt-doctor --gc) упала в прошлый старт: $(cat "$GC_FAIL" 2>/dev/null). Хвосты могут копиться. Запусти вручную: bash \"$WT_SCRIPTS/wt-doctor.sh\" --gc --repo \"$REPO_ROOT\""
fi

(
    if bash "$WT_SCRIPTS/wt-doctor.sh" --gc --repo "$REPO_ROOT" >"$GC_LOG" 2>&1; then
        rm -f "$GC_FAIL" 2>/dev/null || true
    else
        printf 'GC exit=%s (лог: %s)\n' "$?" "$GC_LOG" >"$GC_FAIL" 2>/dev/null || true
    fi
) >/dev/null 2>&1 </dev/null &

# ─── 2. Главный checkout или worktree? ───────────────────────────────────────
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null || echo "")"
GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$PWD/$GIT_COMMON" ;; esac
GIT_DIR="$(cd "$GIT_DIR" 2>/dev/null && pwd -P)"
GIT_COMMON="$(cd "$GIT_COMMON" 2>/dev/null && pwd -P)"

MSGS=""
if [ -n "$GIT_DIR" ] && [ "$GIT_DIR" = "$GIT_COMMON" ]; then
    DIRTY_COUNT="$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$WT_ENFORCE" = "warn" ]; then
        HOW="Правки в главном checkout не рекомендуются (enforce=warn)."
    else
        HOW="Правки файлов в главном checkout заблокированы (enforce=block)."
    fi
    MSGS="Сессия стартовала в ГЛАВНОМ checkout. ${HOW} Несколько сессий в одном дереве смешивают правки. ПЕРВЫМ действием запусти: bash \"$WT_SCRIPTS/wt\" start — он создаст изолированный worktree и напечатает WORKTREE_PATH; дальше работай оттуда (cd и абсолютные пути файлов внутри него). В главном дереве уже ${DIRTY_COUNT} изменённых отслеживаемых файлов (возможно, хвост другой сессии): не коммить их как свои."
fi
if [ -n "$GC_FAIL_MSG" ]; then
    [ -n "$MSGS" ] && MSGS="$MSGS

"
    MSGS="${MSGS}${GC_FAIL_MSG}"
fi

[ -n "$MSGS" ] || exit 0
python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
' "$MSGS" 2>/dev/null
exit 0

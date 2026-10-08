#!/usr/bin/env bash
# session-resolve.sh — резолвер session-state.
#
# Резолвит путь к RESUME.md / .planning ТЕКУЩЕЙ сессии. Ключевая защита (fail-closed):
# в СЕССИОННОМ контексте (linked worktree или ветка <prefix>/*) резолвер НЕ отдаёт чужой
# корневой RESUME молча. Корневой разрешён только если он принадлежит ЭТОЙ сессии
# (session_id совпал) — иначе печатает маркер SESSION_RESUME_AMBIGUOUS и выходит с кодом 1.
# Вне сессионного контекста (main-checkout) — корневой fallback без шума.
#
# Признак «я в сессии» = реальный worktree или ветка <prefix>/*, а НЕ наличие session id:
# id задан в Claude Code всегда. Дёшево: только локальные git-команды (хук SessionStart).
#
# Правило резолва RESUME:
#   1. CLAUDE_CODE_SESSION_ID → .planning/sessions/<sid>/RESUME.md
#   2. Сессионный контекст без своего RESUME: корневой мой → отдать; иначе AMBIGUOUS + exit 1
#   3. Не сессионный контекст → корневой .planning/RESUME.md
#   4. Фолбэк-каталог ($AWK_FALLBACK_DIR или ~/.claude/workflow-kit/sessions/.planning)
#
# Usage:
#   session-resolve.sh [resume|planning] [--cwd <dir>]
#     resume   (default) → абсолютный путь к RESUME.md; не найдено → exit 1
#     planning           → путь к .planning/ сессии (session-dir или корневой)
#
# Prefix ветки сессии: <repo>/.claude/workflow-kit.json, ключ "prefix" (по умолчанию "claude").
# Exit codes: 0 = найдено, 1 = не найдено / ambiguous, 2 = ошибка аргументов.

set -uo pipefail

MODE="resume"
START="$PWD"

while [ $# -gt 0 ]; do
    case "$1" in
        resume|planning) MODE="$1"; shift ;;
        --cwd) START="$2"; shift 2 ;;
        *) echo "session-resolve: неизвестный аргумент '$1'" >&2; exit 2 ;;
    esac
done

FALLBACK="${AWK_FALLBACK_DIR:-${HOME}/.claude/workflow-kit/sessions/.planning}"
AMBIGUOUS_MARKER="SESSION_RESUME_AMBIGUOUS"

# Значение из <repo>/.claude/workflow-kit.json: conf_get <key> <default>
conf_get() {
    local root
    root="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [ -z "$root" ]; then echo "$2"; return; fi
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2]) or sys.argv[3])
except Exception:
    print(sys.argv[3])' "$root/.claude/workflow-kit.json" "$1" "$2"
}
PREFIX="$(conf_get prefix claude)"

# ─── Корневой .planning/ (walk-up) ───────────────────────────────────────────
find_root_planning() {
    local dir="$START"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.planning" ]; then
            echo "$dir/.planning"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# ─── .planning главного чекаута ──────────────────────────────────────────────
# Якорит session-dir в ГЛАВНЫЙ чекаут → переживает удаление своего worktree.
# Rewrite только если common-dir заканчивается на /.git (иначе bare/submodule) —
# тогда fallback на show-toplevel текущего чекаута.
find_main_planning() {
    local common common_abs main_root top
    common="$(git -C "$START" rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [ -n "$common" ]; then
        common_abs="$(cd "$START" 2>/dev/null && cd "$(dirname "$common")" 2>/dev/null && pwd)/$(basename "$common")"
        if [ "$(basename "$common_abs")" = ".git" ]; then
            main_root="$(dirname "$common_abs")"
            if [ -d "$main_root" ]; then
                echo "$main_root/.planning"
                return 0
            fi
        fi
    fi
    top="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] && { echo "$top/.planning"; return 0; }
    return 1
}

# ─── Я в сессионном контексте? (linked worktree ИЛИ ветка <prefix>/*) ─────────
in_session_context() {
    local common gitdir
    common="$(git -C "$START" rev-parse --git-common-dir 2>/dev/null || echo "")"
    gitdir="$(git -C "$START" rev-parse --git-dir 2>/dev/null || echo "")"
    if [ -n "$common" ] && [ -n "$gitdir" ]; then
        local c g
        c="$(cd "$START" 2>/dev/null && cd "$(dirname "$common")" 2>/dev/null && pwd)/$(basename "$common")"
        g="$(cd "$START" 2>/dev/null && cd "$(dirname "$gitdir")" 2>/dev/null && pwd)/$(basename "$gitdir")"
        [ "$c" != "$g" ] && return 0
    fi
    local br
    br="$(git -C "$START" branch --show-current 2>/dev/null || echo "")"
    case "$br" in
        "$PREFIX"/*) return 0 ;;
    esac
    return 1
}

# ─── full-SID: env → манифест .claude/worktrees/<short>.json по ветке ─────────
resolve_full_sid() {
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        echo "$CLAUDE_CODE_SESSION_ID"
        return 0
    fi
    local br short repo_common manifest common_abs
    br="$(git -C "$START" branch --show-current 2>/dev/null || echo "")"
    case "$br" in
        "$PREFIX"/*) short="${br#"$PREFIX"/}" ;;
        *) return 1 ;;
    esac
    repo_common="$(git -C "$START" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [ -z "$repo_common" ] && return 1
    common_abs="$(cd "$START" 2>/dev/null && cd "$(dirname "$repo_common")" 2>/dev/null && pwd)"
    [ -z "$common_abs" ] && return 1
    manifest="$common_abs/.claude/worktrees/${short}.json"
    [ -f "$manifest" ] || return 1
    python3 - "$manifest" <<'PYEOF' 2>/dev/null || return 1
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("session_id", ""))
except Exception:
    sys.exit(1)
PYEOF
}

# ─── Корневой RESUME принадлежит ЭТОЙ сессии? (по session_id) ─────────────────
root_belongs_to_me() {
    local root_resume="$1" my_sid="$2"
    [ -f "$root_resume" ] || return 1
    [ -n "$my_sid" ] || return 1
    local root_sid
    root_sid="$(grep -m1 '^session_id:' "$root_resume" 2>/dev/null | sed 's/^session_id:[[:space:]]*//' || echo "")"
    [ -n "$root_sid" ] || return 1
    [ "$root_sid" = "$my_sid" ]
}

ROOT_PLANNING="$(find_root_planning 2>/dev/null || true)"
MAIN_PLANNING="$(find_main_planning 2>/dev/null || echo "")"
SESS_BASE="${MAIN_PLANNING:-$ROOT_PLANNING}"

# Корня нет → фолбэк-каталог
if [ -z "$ROOT_PLANNING" ]; then
    if [ "$MODE" = "planning" ]; then
        [ -d "$FALLBACK" ] && { echo "$FALLBACK"; exit 0; }
        exit 1
    fi
    if [ -f "$FALLBACK/RESUME.md" ]; then
        echo "$FALLBACK/RESUME.md"; exit 0
    fi
    exit 1
fi

# ─── 1. Session-scoped ───────────────────────────────────────────────────────
FULL_SID="$(resolve_full_sid 2>/dev/null || echo "")"
if [ -n "$FULL_SID" ]; then
    SESS_DIR="$SESS_BASE/sessions/$FULL_SID"
    if [ "$MODE" = "planning" ] && [ -d "$SESS_DIR" ]; then
        echo "$SESS_DIR"; exit 0
    fi
    if [ "$MODE" = "resume" ] && [ -f "$SESS_DIR/RESUME.md" ]; then
        echo "$SESS_DIR/RESUME.md"; exit 0
    fi
fi

# ─── 2. Сессионный контекст без своего RESUME → fail-closed на чужой корневой ─
if in_session_context; then
    if [ "$MODE" = "planning" ]; then
        if [ -n "$FULL_SID" ]; then
            echo "$SESS_BASE/sessions/$FULL_SID"; exit 0
        fi
        echo "$ROOT_PLANNING"; exit 0
    fi
    if root_belongs_to_me "$ROOT_PLANNING/RESUME.md" "$FULL_SID"; then
        echo "$ROOT_PLANNING/RESUME.md"; exit 0
    fi
    echo "$AMBIGUOUS_MARKER"
    exit 1
fi

# ─── 3. Не сессионный контекст → корневой fallback ───────────────────────────
if [ "$MODE" = "planning" ]; then
    echo "$ROOT_PLANNING"; exit 0
fi
if [ -f "$ROOT_PLANNING/RESUME.md" ]; then
    echo "$ROOT_PLANNING/RESUME.md"; exit 0
fi

# ─── 4. Фолбэк-каталог ───────────────────────────────────────────────────────
if [ -f "$FALLBACK/RESUME.md" ]; then
    echo "$FALLBACK/RESUME.md"; exit 0
fi

exit 1

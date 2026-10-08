#!/usr/bin/env bash
# wt-pretooluse-guard.sh — PreToolUse барьер worktree-изоляции.
# Блокирует правку файлов в ГЛАВНОМ checkout репозитория, где включён модуль
# (.claude/workflow-kit.json, enabled=true). Запускается через guard-runner.sh
# (он держит fail-closed и нормализует коды).
#
# Контракт кодов:
#   0 — разрешить / правило неприменимо (не тот инструмент, не репозиторий, модуль выключен,
#       файл в linked worktree, enforce=warn)
#   2 — блок (enforce=block, по умолчанию)
#   1 — внутренняя ошибка (битый payload, нет python3) → раннер решает по fail-mode
#
# Тип checkout определяется по метаданным git (--absolute-git-dir против --git-common-dir),
# а не по имени ветки. Репозиторий — по ПУТИ ПРАВИМОГО ФАЙЛА из payload, а не по cwd:
# правка файла вне проекта из main-checkout не блокируется.
#
# Обход: WT_ALLOW_MAIN=1 в окружении Claude Code, либо временный файл обхода guard-runner
# (см. шапку scripts/guards/guard-runner.sh, имя охранника: worktree).

set -uo pipefail

GUARD_PY="${GUARD_PY:-python3}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_BIN="$(cd "$HOOK_DIR/.." && pwd)/wt"

[ -t 0 ] && exit 0

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

PARSED="$(printf '%s' "$INPUT" | "$GUARD_PY" -c '
import json, sys
d = json.load(sys.stdin)
ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    ti = {}
path = ti.get("file_path") or ti.get("notebook_path") or ""
print(d.get("tool_name", "") or "")
print(path if isinstance(path, str) else "")
' 2>/dev/null)" || {
    echo "wt-guard: не удалось разобрать payload (tool_name/file_path)" >&2
    exit 1
}

TOOL_NAME="$(printf '%s\n' "$PARSED" | sed -n '1p')"
FILE_PATH="$(printf '%s\n' "$PARSED" | sed -n '2p')"

case "$TOOL_NAME" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

# --- каталог, по которому судим: путь файла из payload, иначе cwd ---
TARGET_DIR="$PWD"
if [ -n "$FILE_PATH" ]; then
    case "$FILE_PATH" in
        /*) CAND="$(dirname "$FILE_PATH")" ;;
        *)  CAND="$(dirname "$PWD/$FILE_PATH")" ;;
    esac
    # файл может ещё не существовать (Write) — поднимаемся до существующего каталога
    while [ -n "$CAND" ] && [ "$CAND" != "/" ] && [ ! -d "$CAND" ]; do
        CAND="$(dirname "$CAND")"
    done
    [ -d "$CAND" ] && TARGET_DIR="$CAND"
fi

command -v git >/dev/null 2>&1 || { echo "wt-guard: git не найден" >&2; exit 1; }

# --- тип checkout по метаданным git ---
GIT_DIR="$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
[ -n "$GIT_DIR" ] || exit 0

GIT_COMMON="$(cd "$TARGET_DIR" && git rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$GIT_COMMON" in
    /*) ;;
    *)  GIT_COMMON="$TARGET_DIR/$GIT_COMMON" ;;
esac

GIT_DIR="$(cd "$GIT_DIR" 2>/dev/null && pwd -P)" || exit 0
GIT_COMMON="$(cd "$GIT_COMMON" 2>/dev/null && pwd -P)" || exit 0

MAIN_ROOT="$(dirname "$GIT_COMMON")"

# --- конфиг проекта ---
CFG="$MAIN_ROOT/.claude/workflow-kit.json"
[ -f "$CFG" ] || exit 0

CFG_PARSED="$(CFG_PATH="$CFG" "$GUARD_PY" -c '
import json, os
d = json.load(open(os.environ["CFG_PATH"]))
print("true" if d.get("enabled") is True else "false")
print(d.get("enforce", "block"))
' 2>/dev/null)" || {
    echo "wt-guard: битый или нечитаемый $CFG" >&2
    exit 1
}

ENABLED="$(printf '%s\n' "$CFG_PARSED" | sed -n '1p')"
ENFORCE="$(printf '%s\n' "$CFG_PARSED" | sed -n '2p')"
[ "$ENABLED" = "true" ] || exit 0

# сообщить раннеру реальный режим: fail-closed нужен только при block
if [ -n "${GUARD_MODE_FILE:-}" ]; then
    case "$ENFORCE" in
        warn) printf 'warn\n'  >"$GUARD_MODE_FILE" 2>/dev/null || true ;;
        *)    printf 'block\n' >"$GUARD_MODE_FILE" 2>/dev/null || true ;;
    esac
fi

# linked worktree: git-dir отличается от общего git-dir
[ "$GIT_DIR" != "$GIT_COMMON" ] && exit 0

# --- мы в главном checkout ---
[ "${WT_ALLOW_MAIN:-}" = "1" ] && exit 0

BRANCH="$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || echo "")"
MSG="wt-guard: правка файла в главном checkout ${MAIN_ROOT} (ветка: ${BRANCH:-HEAD detached}). Сначала создай worktree: bash \"${WT_BIN}\" start, затем повтори правку по пути внутри напечатанного WORKTREE_PATH. Обход (осознанно): WT_ALLOW_MAIN=1 в окружении Claude Code или временный файл обхода guard-runner (имя: worktree)."

if [ "$ENFORCE" = "warn" ]; then
    "$GUARD_PY" -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.argv[1]}}))
' "$MSG"
    exit 0
fi

echo "$MSG" >&2
exit 2

#!/usr/bin/env bash
# guard-runner.sh — fail-closed обёртка для guard-хуков.
#
# Usage:
#   guard-runner.sh --name <guard> [--fail-mode block|warn] [--timeout <sec>] -- <hook> [args...]
#
# Трансляция кодов хука:
#   0             -> 0  (разрешить / правило неприменимо)
#   2             -> 2  (штатный блок)
#   иное (1/127/255/сигнал/таймаут) -> внутренняя ошибка:
#       fail-mode=block -> exit 2 (fail-closed) + GUARD_INTERNAL_ERROR в stderr
#       fail-mode=warn  -> exit 0 + диагностический additionalContext
#
# Уточнение режима: хук может записать "warn" или "block" в $GUARD_MODE_FILE, как только
# вычислит режим проекта. Раннер уважает эту запись. Ранний крах (до записи) -> файла нет
# -> берётся --fail-mode. Так fail-closed срабатывает там, где барьер действительно
# блокирующий, а логика режима не дублируется вне хука.
#
# Аварийный обход: файл $GUARD_HOME/run/guard-bypass/<guard> (проверяется до запуска хука):
#   mkdir -p ~/.claude/workflow-kit/run/guard-bypass
#   printf 'expires_at=%s\nreason=%s\n' "$(( $(date +%s) + 600 ))" "причина" \
#       > ~/.claude/workflow-kit/run/guard-bypass/<guard>
# Просроченный или битый файл удаляется сам. Снять обход раньше срока: удалить файл.
#
# Внутри — только нормализация кодов, таймаут, bypass и диагностика. Доменной логики нет.

set -uo pipefail

GUARD_HOME="${GUARD_RUNNER_HOME:-${HOME:-/tmp}/.claude/workflow-kit}"
BYPASS_DIR="$GUARD_HOME/run/guard-bypass"
LOG_DIR="$GUARD_HOME/logs"

NAME=""
FAIL_MODE="warn"
TIMEOUT_SECS="8"

while [ $# -gt 0 ]; do
    case "$1" in
        --name)      NAME="${2:-}"; shift 2 ;;
        --fail-mode) FAIL_MODE="${2:-warn}"; shift 2 ;;
        --timeout)   TIMEOUT_SECS="${2:-8}"; shift 2 ;;
        --)          shift; break ;;
        *)           break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "guard-runner: не задан хук (usage: --name X [--fail-mode block|warn] [--timeout N] -- <hook>)" >&2
    exit 2
fi

HOOK_PATH="$1"
[ -n "$NAME" ] || NAME="$(basename "$HOOK_PATH")"

log_line() {
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$NAME" "$1" >>"$LOG_DIR/guard-runner.log" 2>/dev/null || true
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

emit_context() {
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "additionalContext": "%s"\n  }\n}\n' "$(json_escape "$1")"
}

# --- аварийный обход (проверяется ДО запуска хука: работает и когда хук мёртв) ---
BYPASS_FILE="$BYPASS_DIR/$NAME"
if [ -f "$BYPASS_FILE" ]; then
    BY_EXP="$(sed -n 's/^expires_at=//p' "$BYPASS_FILE" 2>/dev/null | head -1)"
    BY_REASON="$(sed -n 's/^reason=//p' "$BYPASS_FILE" 2>/dev/null | head -1)"
    NOW="$(date +%s)"
    case "$BY_EXP" in
        ''|*[!0-9]*) rm -f "$BYPASS_FILE" 2>/dev/null || true ;;
        *)
            if [ "$NOW" -lt "$BY_EXP" ]; then
                log_line "bypass-used until=$BY_EXP reason=${BY_REASON:-—}"
                exit 0
            fi
            rm -f "$BYPASS_FILE" 2>/dev/null || true
            ;;
    esac
fi

# --- запуск хука ---
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/guard-runner.XXXXXX")" || {
    echo "GUARD_INTERNAL_ERROR: $NAME — не удалось создать временный каталог" >&2
    exit 2
}
trap 'rm -rf "$TMPD"' EXIT

PAYLOAD="$TMPD/payload"
OUT="$TMPD/out"
ERR="$TMPD/err"
TFLAG="$TMPD/timeout"
MODE_FILE="$TMPD/mode"

if [ -t 0 ]; then
    : >"$PAYLOAD"
else
    cat >"$PAYLOAD"
fi

export GUARD_MODE_FILE="$MODE_FILE"
export GUARD_NAME="$NAME"

if [ -x "$HOOK_PATH" ]; then
    "$@" <"$PAYLOAD" >"$OUT" 2>"$ERR" &
else
    bash "$@" <"$PAYLOAD" >"$OUT" 2>"$ERR" &
fi
HOOK_PID=$!

(
    sleep "$TIMEOUT_SECS"
    if kill -0 "$HOOK_PID" 2>/dev/null; then
        : >"$TFLAG"
        kill -TERM "$HOOK_PID" 2>/dev/null
        sleep 1
        kill -KILL "$HOOK_PID" 2>/dev/null
    fi
) >/dev/null 2>&1 </dev/null &
WD_PID=$!

wait "$HOOK_PID"
RC=$?
kill "$WD_PID" 2>/dev/null
wait "$WD_PID" 2>/dev/null

# --- режим, уточнённый хуком ---
if [ -s "$MODE_FILE" ]; then
    HOOK_MODE="$(head -1 "$MODE_FILE" | tr -d '[:space:]')"
    case "$HOOK_MODE" in
        block|warn) FAIL_MODE="$HOOK_MODE" ;;
    esac
fi

case "$RC" in
    0)
        cat "$OUT"
        exit 0
        ;;
    2)
        cat "$OUT"
        cat "$ERR" >&2
        exit 2
        ;;
esac

# --- внутренняя ошибка ---
CAUSE="exit=$RC"
if [ -f "$TFLAG" ]; then
    CAUSE="timeout ${TIMEOUT_SECS}s (exit=$RC)"
elif [ "$RC" -gt 128 ] 2>/dev/null; then
    CAUSE="signal $((RC - 128)) (exit=$RC)"
fi

STDERR_TAIL="$(tail -3 "$ERR" 2>/dev/null | tr '\n' ' ')"
[ -n "$STDERR_TAIL" ] || STDERR_TAIL="(пусто)"

MSG="GUARD_INTERNAL_ERROR: барьер '$NAME' не отработал. hook=$HOOK_PATH; причина: $CAUSE; stderr: $STDERR_TAIL. Починить: bash -n $HOOK_PATH и запустить руками с тем же payload. Обойти на время: файл ${BYPASS_FILE} со строками expires_at=<epoch> и reason=<причина>."

log_line "internal-error $CAUSE mode=$FAIL_MODE stderr=$STDERR_TAIL"

if [ "$FAIL_MODE" = "block" ]; then
    echo "$MSG" >&2
    exit 2
fi

emit_context "$MSG (fail-mode=warn — пропускаю, но барьер сломан)"
exit 0

#!/usr/bin/env bash
# wt-doctor.sh — диагностика и reversible GC worktree-веток.
# Совместим с bash 3.2 (macOS default).
#
# Использование:
#   bash wt-doctor.sh [--gc] [--repo <path>] [--ttl-days <N>]
#
# Без флагов: read-only, таблица вердиктов.
# --gc          : удалить локальные ветки TREE_IDENTICAL_SAFE / BEHIND_ONLY_SAFE
#                 (worktree нет), с backup-ref в refs/wt-trash/ перед удалением.
#                 Удалённые (origin) ветки --gc не трогает.
# --repo        : путь к репо (default: поиск по иерархии от CWD)
# --ttl-days    : сколько дней хранить refs/wt-trash/* (default: 30)
# --idle-days   : порог заброшенности для уникальных веток (default: 14)
# --reap-idle   : + удалять заброшенные ветки с уникальными коммитами (backup-ref сохраняется)
# --prune-remote: + обрезать origin/<prefix>/* влитые-в-base старше --idle-days (push --delete)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wt-lib.sh
source "$SCRIPT_DIR/wt-lib.sh"

# ─── Параметры ──────────────────────────────────────────────────────────────
GC_MODE=false
REPO_ARG=
TTL_DAYS=30
IDLE_DAYS=14   # порог заброшенности для HAS_UNIQUE worktree (B2-а)
REAP_IDLE=false   # удалять заброшенные уникальные ветки (необратимо-без-backup → явный opt-in, НЕ под --gc)
PRUNE_REMOTE=false   # обрезка origin/<prefix>/* merged-в-base старше IDLE_DAYS (B2-б)

while [ $# -gt 0 ]; do
    case "$1" in
        --gc)         GC_MODE=true; shift ;;
        --repo)       REPO_ARG="$2"; shift 2 ;;
        --ttl-days)   TTL_DAYS="$2"; shift 2 ;;
        --idle-days)  IDLE_DAYS="$2"; shift 2 ;;
        --reap-idle)  REAP_IDLE=true; GC_MODE=true; shift ;;
        --prune-remote) PRUNE_REMOTE=true; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    esac
done

# ─── Найти репо ─────────────────────────────────────────────────────────────
if [ -n "$REPO_ARG" ]; then
    REPO_ROOT="$REPO_ARG"
else
    REPO_ROOT="$(wt_find_repo_root "$PWD")" || {
        echo "wt-doctor: не найдено git-репо (CWD=$PWD)" >&2
        exit 1
    }
fi

# ─── Загрузить конфиг ───────────────────────────────────────────────────────
wt_load_config "$REPO_ROOT"

if [ "$WT_ENABLED" != "true" ]; then
    if [ -t 1 ]; then
        echo "wt-doctor: .claude/workflow-kit.json не найден или enabled:false — диагностика пропущена."
        echo "  (Для включения: создайте .claude/workflow-kit.json с {\"enabled\": true})"
    fi
    exit 0
fi

SESSION_ID="$(wt_session_id)"
PREFIX="$WT_PREFIX"
BASE="$WT_BASE"
CURRENT_SID="${SESSION_ID:0:8}"

# ─── Собираем ветки ─────────────────────────────────────────────────────────
BRANCHES_LIST="$(wt_list_branches "$REPO_ROOT" "$PREFIX")"

if [ -z "$BRANCHES_LIST" ]; then
    echo "wt-doctor [$(basename "$REPO_ROOT")]: нет веток с префиксом '${PREFIX}/'."
    exit 0
fi

# ─── Заголовок ──────────────────────────────────────────────────────────────
REPO_NAME="$(basename "$REPO_ROOT")"
echo ""
echo "wt-doctor: репо=${REPO_NAME}  base=${BASE}  prefix=${PREFIX}  gc=${GC_MODE}"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""
printf "%-40s %-22s %-6s %s\n" "ВЕТКА" "КАТЕГОРИЯ" "ДНЕЙ" "WORKTREE"
printf '%0.s─' {1..100}; echo ""

GC_DELETED=0
GC_SKIPPED=0

# ─── Перебираем ветки ───────────────────────────────────────────────────────
PREV_BRANCH=""
while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    # Дедуп (sort -u уже даёт уникальные, но на всякий случай)
    [ "$branch" = "$PREV_BRANCH" ] && continue
    PREV_BRANCH="$branch"

    local_sid="${branch##*/}"
    local_sid="${local_sid:0:8}"

    # Remote-only ветка (есть в origin/, нет локально): git rev-parse падает и под set -e
    # глушит ВЕСЬ GC-проход. Такие ветки локальными операциями не трогаем, только показываем.
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
        printf "%-40s %-22s %-6s %s\n" "$branch" "REMOTE_ONLY" "?д" "(только origin/, локально нет)"
        continue
    fi

    category="$(wt_classify_branch "$REPO_ROOT" "$branch" "$BASE")"
    age="$(wt_branch_age_days "$REPO_ROOT" "$branch")"
    wt_path="$(wt_find_worktree_path "$REPO_ROOT" "$branch")"

    wt_label="(нет worktree)"
    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
        wt_label="$wt_path"
        if [ -n "$CURRENT_SID" ] && [ "${local_sid}" = "${CURRENT_SID}" ]; then
            wt_label="$wt_label [CURRENT]"
        fi
    fi

    printf "%-40s %-22s %-6s %s\n" "$branch" "$category" "${age}д" "$wt_label"

    # ─── GC ─────────────────────────────────────────────────────────────────
    if $GC_MODE; then
        # SAFE-категории удаляем безусловно. Уникальные ветки
        # (HAS_UNIQUE / ACTIVE_CLEAN) — только если заброшены (idle > IDLE_DAYS):
        # это backup-ref-обратимое удаление, но содержимое НЕ в base, поэтому
        # за порогом времени, чтобы не убить активную работу. (B2-а)
        # ACTIVE_* (worktree существует на диске) не попадает НИ в одну ветку ниже →
        # is_safe=false, is_idle_unique=false → фон не трогает. Это инвариант
        # классификатора (wt-lib.sh): директория на диске = факт живости.
        # ACTIVE_CLEAN остаётся кандидатом на РУЧНОЙ --reap-idle: там уникальные коммиты,
        # и они сохранны в backup-ref.
        is_safe=false
        is_idle_unique=false
        case "$category" in
            TREE_IDENTICAL_SAFE|BEHIND_ONLY_SAFE) is_safe=true ;;
            HAS_UNIQUE|ACTIVE_CLEAN)
                if [ "$age" != "?" ] && [ "$age" -gt "$IDLE_DAYS" ]; then
                    is_idle_unique=true
                fi
                ;;
            ACTIVE_EMPTY|ACTIVE_DIRTY) : ;;   # живая сессия — не трогаем никогда
        esac

        # SAFE → удаляем (потеря нулевая, безопасно и в фоне).
        # idle-unique → удаляем ТОЛЬКО при явном --reap-idle (1 клик на необратимом);
        #   под обычным --gc лишь сигналим кандидата, не трогаем.
        if $is_idle_unique && ! $REAP_IDLE; then
            echo "    → idle ${age}д > ${IDLE_DAYS}д, уникальные изменения. Удалить: wt-doctor --reap-idle"
            continue
        fi
        if ! $is_safe && ! $is_idle_unique; then
            continue
        fi

        if $is_idle_unique; then
            echo "    → reap idle ${age}д > ${IDLE_DAYS}д: уникальные изменения (backup-ref сохранит)"
        fi

        # Не трогаем текущую сессию
        if [ -n "$CURRENT_SID" ] && [ "$local_sid" = "$CURRENT_SID" ]; then
            echo "    → SKIP (текущая сессия)"
            GC_SKIPPED=$(( GC_SKIPPED + 1 ))
            continue
        fi

        # Не трогаем живую ЧУЖУЮ сессию: свежая сессия без коммитов и правок по git-фактам
        # неотличима от мусора. Живость определяет manifest: status=active + updated_at свежее 24ч.
        if wt_manifest_live "$REPO_ROOT" "$local_sid" 24; then
            echo "    → SKIP (живая сессия: manifest active, updated_at <24ч)"
            GC_SKIPPED=$(( GC_SKIPPED + 1 ))
            continue
        fi

        # Не трогаем dirty worktree
        if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
            dirty="$(git -C "$wt_path" status --porcelain --untracked-files=all 2>/dev/null)"
            if [ -n "$dirty" ]; then
                echo "    → SKIP (dirty worktree)"
                GC_SKIPPED=$(( GC_SKIPPED + 1 ))
                continue
            fi
            git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        fi

        # Backup-ref (reversible!)
        # Имя несёт ВРЕМЯ УДАЛЕНИЯ: refs/wt-trash/<unixts>-<sid>. TTL-чистка ниже считает
        # возраст от него, а не от даты коммита: иначе бэкап старой ветки умирал бы
        # в том же проходе GC.
        sha="$(git -C "$REPO_ROOT" rev-parse "${branch}" 2>/dev/null || true)"
        if [ -n "$sha" ]; then
            backup_ref="refs/wt-trash/$(date +%s)-${local_sid}"
            git -C "$REPO_ROOT" update-ref "$backup_ref" "$sha"
            echo "    → backup: $backup_ref ($sha)"
        fi

        # Удаляем локальную ветку
        if git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null; then
            echo "    → удалена локальная ветка $branch"
        fi

        GC_DELETED=$(( GC_DELETED + 1 ))
    fi

done <<EOF
$BRANCHES_LIST
EOF

printf '%0.s─' {1..100}; echo ""

# ─── GC итог + TTL-чистка wt-trash ─────────────────────────────────────────
if $GC_MODE; then
    echo ""
    echo "GC: удалено=${GC_DELETED}  пропущено=${GC_SKIPPED}"

    TRASH_CLEANED=0
    NOW_TS="$(date +%s)"
    TTL_SECS=$(( TTL_DAYS * 86400 ))

    trash_refs="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' 'refs/wt-trash/' 2>/dev/null || true)"
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        # Возраст — от ВРЕМЕНИ УДАЛЕНИЯ (префикс имени ref), не от даты коммита.
        # Ref без числовой метки никогда не удаляем: времени удаления у него нет.
        ref_name="${ref#refs/wt-trash/}"
        ref_ts="${ref_name%%-*}"
        case "$ref_ts" in
            ''|*[!0-9]*)
                echo "  trash: $ref без метки времени удаления (legacy) → пропущен, чистить вручную"
                continue ;;
        esac
        age_secs=$(( NOW_TS - ref_ts ))
        if [ "$age_secs" -gt "$TTL_SECS" ]; then
            if git -C "$REPO_ROOT" update-ref -d "$ref" 2>/dev/null; then
                echo "  trash cleanup: удалён $ref (старше ${TTL_DAYS}д)"
                TRASH_CLEANED=$(( TRASH_CLEANED + 1 ))
            fi
        fi
    done <<EOF2
$trash_refs
EOF2

    echo "  trash cleanup: очищено=${TRASH_CLEANED} (TTL=${TTL_DAYS}д)"
fi

# ─── B2-б: обрезка влитых remote-веток origin/<prefix>/* ────────────────────
# Влитые в base (git cherry: все патчи воспроизведены) и старше IDLE_DAYS.
# Обновляем origin сначала, чтобы merged-проверка была против свежего base.
if $PRUNE_REMOTE; then
    echo ""
    echo "prune-remote: origin/${PREFIX}/* влитые-в-${BASE} старше ${IDLE_DAYS}д"
    git -C "$REPO_ROOT" fetch --prune origin >/dev/null 2>&1 || true

    NOW_TS="$(date +%s)"
    REMOTE_PRUNED=0
    REMOTE_KEPT=0
    remote_branches="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/remotes/origin/${PREFIX}/" 2>/dev/null || true)"
    while IFS= read -r rb; do
        [ -z "$rb" ] && continue                       # rb = origin/claude/xxxx
        short_branch="${rb#origin/}"                    # claude/xxxx
        rsid="${short_branch##*/}"; rsid="${rsid:0:8}"

        # Не трогаем текущую сессию
        if [ -n "$CURRENT_SID" ] && [ "$rsid" = "$CURRENT_SID" ]; then
            echo "  SKIP $short_branch (текущая сессия)"
            REMOTE_KEPT=$(( REMOTE_KEPT + 1 ))
            continue
        fi

        # Возраст по remote-ref
        r_ts="$(git -C "$REPO_ROOT" log -1 --format='%ct' "$rb" 2>/dev/null || echo 0)"
        r_age=$(( (NOW_TS - r_ts) / 86400 ))
        if [ "$r_age" -le "$IDLE_DAYS" ]; then
            REMOTE_KEPT=$(( REMOTE_KEPT + 1 ))
            continue
        fi

        # Влита ли в base? (по содержимому, squash-safe)
        wt_branch_merged_into "$REPO_ROOT" "$rb" "$BASE"
        merged_rc=$?
        if [ "$merged_rc" -eq 1 ]; then
            echo "  KEEP $short_branch (${r_age}д, есть невлитые коммиты)"
            REMOTE_KEPT=$(( REMOTE_KEPT + 1 ))
            continue
        fi

        # merged (rc=0) или нет уникальных коммитов (rc=2) → безопасно удалить.
        # Backup-ref на remote-sha перед удалением.
        r_sha="$(git -C "$REPO_ROOT" rev-parse "$rb" 2>/dev/null || true)"
        if [ -n "$r_sha" ]; then
            git -C "$REPO_ROOT" update-ref "refs/wt-trash/$(date +%s)-remote-${rsid}" "$r_sha" 2>/dev/null \
                && echo "  backup: refs/wt-trash/$(date +%s)-remote-${rsid} ($r_sha)"
        fi
        if git -C "$REPO_ROOT" push origin --delete "$short_branch" 2>/dev/null; then
            echo "  PRUNE origin/${short_branch} (${r_age}д, влита)"
            REMOTE_PRUNED=$(( REMOTE_PRUNED + 1 ))
        else
            echo "  ⚠ не удалось удалить origin/${short_branch}"
            REMOTE_KEPT=$(( REMOTE_KEPT + 1 ))
        fi
    done <<EOF3
$remote_branches
EOF3
    echo "prune-remote: удалено=${REMOTE_PRUNED}  оставлено=${REMOTE_KEPT}"
fi

# ─── Легенда ────────────────────────────────────────────────────────────────
echo ""
echo "Категории:"
echo "  TREE_IDENTICAL_SAFE  — содержимое идентично ${BASE}, безопасно (--gc)"
echo "  BEHIND_ONLY_SAFE     — нет уникальных diff vs ${BASE}, безопасно (--gc)"
echo "  HAS_UNIQUE           — уникальные изменения, НЕ трогать"
echo "  ACTIVE_DIRTY         — worktree жив и грязный, НЕ трогать"
echo "  ACTIVE_CLEAN         — worktree жив, чист, уникальные коммиты, НЕ трогать"
echo "  ACTIVE_EMPTY         — worktree жив, уникальной работы нет, НЕ трогать (фон)"
echo ""
echo "Восстановление после --gc (имя ref'а = <время-удаления>-<SID>):"
echo "  git for-each-ref --format='%(refname) %(committerdate:short)' refs/wt-trash/   # найти свой"
echo "  git branch <имя> refs/wt-trash/<TS>-<SID>"

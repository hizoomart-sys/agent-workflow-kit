#!/usr/bin/env bash
# wt-lib.sh — общие функции worktree-инструментов (wt, wt-doctor, хуки).
# Совместим с bash 3.2 (macOS). Подключается через source; set -e/-u ставит потребитель.
# Конфиг: <repo>/.claude/workflow-kit.json. Нет файла или enabled != true → WT_ENABLED=false.

WORKFLOW_KIT_HOME="${WORKFLOW_KIT_HOME:-${HOME:-/tmp}/.claude/workflow-kit}"

# ─── Корень ГЛАВНОГО checkout (работает и изнутри linked worktree) ──────────
wt_find_repo_root() {
    local dir="${1:-$PWD}" common
    [ -d "$dir" ] || return 1
    common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in
        /*) ;;
        *) common="$dir/$common" ;;
    esac
    common="$(cd "$common" 2>/dev/null && pwd -P)" || return 1
    dirname "$common"
}

# ─── Конфиг (fail-open) ─────────────────────────────────────────────────────
# Выставляет: WT_ENABLED WT_PREFIX WT_DIR WT_BASE WT_PLANNING_DIR WT_ENFORCE
#             WT_TEST_CMD WT_LINK_FILES (массив)
wt_load_config() {
    local repo_root="$1"
    local cfg="$repo_root/.claude/workflow-kit.json"

    WT_ENABLED=false
    WT_PREFIX=claude
    WT_DIR=.claude/worktrees
    WT_BASE=main
    WT_PLANNING_DIR=.planning
    WT_ENFORCE=block
    WT_TEST_CMD=
    WT_LINK_FILES=()

    [ -f "$cfg" ] || return 0

    local py_out kv key val
    py_out="$(python3 - "$cfg" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    for k in ["enabled", "prefix", "worktreeDir", "base", "planningDir", "enforce", "testCommand"]:
        v = d.get(k, "")
        if isinstance(v, bool):
            v = "true" if v else "false"
        if isinstance(v, str):
            v = v.replace("\n", " ")
        if v != "":
            print("%s=%s" % (k, v))
    lf = d.get("linkFiles", [])
    if isinstance(lf, list):
        for item in lf:
            if isinstance(item, str) and item and not item.startswith("/") and ".." not in item.split("/"):
                print("linkFile=%s" % item)
except Exception:
    pass
PYEOF
    )"

    while IFS= read -r kv; do
        [ -z "$kv" ] && continue
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            enabled)     WT_ENABLED="$val" ;;
            prefix)      WT_PREFIX="$val" ;;
            worktreeDir) WT_DIR="$val" ;;
            base)        WT_BASE="$val" ;;
            planningDir) WT_PLANNING_DIR="$val" ;;
            enforce)     WT_ENFORCE="$val" ;;
            testCommand) WT_TEST_CMD="$val" ;;
            linkFile)    WT_LINK_FILES+=("$val") ;;
        esac
    done <<EOF
$py_out
EOF
    return 0
}

wt_session_id() {
    echo "${CLAUDE_CODE_SESSION_ID:-}"
}

# ─── Ветки сессий: по префиксу + ветки linked worktrees (кроме главного) ────
wt_list_branches() {
    local repo_root="$1" prefix="$2"
    {
        git -C "$repo_root" branch --list "${prefix}/*" --format='%(refname:short)' 2>/dev/null
        git -C "$repo_root" branch -r --list "origin/${prefix}/*" --format='%(refname:short)' 2>/dev/null \
            | sed 's|^origin/||'
        git -C "$repo_root" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree / { n++ } n > 1 && /^branch refs\/heads\// { print substr($2, 12) }'
    } | grep -v -x -e "${WT_BASE:-main}" | sort -u
}

# ─── Путь worktree для ветки (пустой вывод, если нет) ───────────────────────
wt_find_worktree_path() {
    local repo_root="$1" branch="$2"
    git -C "$repo_root" worktree list --porcelain 2>/dev/null \
        | awk -v br="$branch" '
            /^worktree / { wt=substr($0,10) }
            /^branch refs\/heads\// { b=substr($0,19) }
            /^$/ { if(b==br) print wt; wt=""; b="" }
            END { if(b==br) print wt }
          '
}

# worktree <path> зарегистрирован в git? (точное совпадение пути)
wt_worktree_registered() {
    local repo_root="$1" path="$2"
    git -C "$repo_root" worktree list --porcelain 2>/dev/null \
        | awk -v p="$path" '/^worktree / { if (substr($0,10)==p) found=1 } END { exit found?0:1 }'
}

# ─── Грязные файлы worktree (без симлинков из linkFiles) ────────────────────
wt_dirty_files() {
    local path="$1" out line f skip
    out="$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null)"
    [ -z "$out" ] && return 0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        skip=false
        for f in ${WT_LINK_FILES[@]+"${WT_LINK_FILES[@]}"}; do
            [ "${line#\?\? }" = "${f%/}" ] && { skip=true; break; }
        done
        $skip || printf '%s\n' "$line"
    done <<EOF
$out
EOF
    return 0
}

# ─── Классификатор ветки ────────────────────────────────────────────────────
# ИНВАРИАНТ: worktree существует на диске ⇒ категория ACTIVE_* и только она.
# Суффикс _SAFE («можно удалить в фоне») допустим ТОЛЬКО когда директории worktree нет.
# Директория на диске — факт живости; возраст манифеста — лишь эвристика.
#   ACTIVE_DIRTY  — есть незакоммиченные/untracked файлы
#   ACTIVE_CLEAN  — чисто, есть уникальные коммиты
#   ACTIVE_EMPTY  — чисто, уникальной работы нет (свежая сессия или отстала от base)
#   TREE_IDENTICAL_SAFE — worktree нет, содержимое идентично base
#   BEHIND_ONLY_SAFE    — worktree нет, 3-точечный diff пуст
#   HAS_UNIQUE          — worktree нет, есть уникальные изменения
wt_classify_branch() {
    local repo_root="$1" branch="$2" base="$3"

    local wt_path wt_dirty=false
    wt_path="$(wt_find_worktree_path "$repo_root" "$branch")"
    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
        [ -n "$(wt_dirty_files "$wt_path")" ] && wt_dirty=true
    fi

    local unique_commits
    unique_commits="$(git -C "$repo_root" log --oneline "${base}...${branch}" --right-only 2>/dev/null | wc -l | tr -d ' \t')"

    local tree_identical=false
    git -C "$repo_root" diff --quiet "${base}" "${branch}" -- 2>/dev/null && tree_identical=true

    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
        if $wt_dirty; then
            echo "ACTIVE_DIRTY"
        elif [ "$unique_commits" -gt 0 ] && ! $tree_identical; then
            echo "ACTIVE_CLEAN"
        else
            echo "ACTIVE_EMPTY"
        fi
    else
        if $tree_identical; then
            echo "TREE_IDENTICAL_SAFE"
        else
            local diff_out
            diff_out="$(git -C "$repo_root" diff "${base}...${branch}" 2>/dev/null)"
            if [ -z "$diff_out" ]; then
                echo "BEHIND_ONLY_SAFE"
            else
                echo "HAS_UNIQUE"
            fi
        fi
    fi
}

# ─── Manifest сессии: <repo>/<worktreeDir>/<sid>.json ───────────────────────
wt_manifest_path() {
    local repo_root="$1" sid="$2"
    echo "${repo_root}/${WT_DIR:-.claude/worktrees}/${sid}.json"
}

# Поля: session_id, sid_short, branch, worktree_path, created_at, updated_at, status, intended_merge
wt_write_manifest() {
    local repo_root="$1" sid="$2" full_sid="$3" branch="$4" wt_path="$5" base="${6:-${WT_BASE:-main}}"
    local manifest now
    manifest="$(wt_manifest_path "$repo_root" "$sid")"
    mkdir -p "$(dirname "$manifest")"
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    python3 - "$manifest" "$full_sid" "$sid" "$branch" "$wt_path" "$now" "$base" <<'PYEOF'
import json, sys
path, full_sid, sid, branch, wt_path, now, base = sys.argv[1:]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
d.update({
    "session_id": full_sid,
    "sid_short": sid,
    "branch": branch,
    "worktree_path": wt_path,
    "created_at": d.get("created_at", now),
    "updated_at": now,
    "status": "active",
    "intended_merge": base,
})
with open(path, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

wt_update_manifest_status() {
    local repo_root="$1" sid="$2" status="$3"
    local manifest now
    manifest="$(wt_manifest_path "$repo_root" "$sid")"
    [ -f "$manifest" ] || return 0
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    python3 - "$manifest" "$status" "$now" <<'PYEOF'
import json, sys
path, status, now = sys.argv[1:]
try:
    with open(path) as f:
        d = json.load(f)
    d["status"] = status
    d["updated_at"] = now
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
except Exception:
    pass
PYEOF
}

# Живость сессии по manifest: 0 = status=active и updated_at свежее max_hours, иначе 1.
# Свежий worktree без коммитов по git-фактам неотличим от мусора — живость задаёт manifest.
wt_manifest_live() {
    local repo_root="$1" sid="$2" max_hours="${3:-24}"
    local manifest
    manifest="$(wt_manifest_path "$repo_root" "$sid")"
    [ -f "$manifest" ] || return 1
    python3 - "$manifest" "$max_hours" <<'PYEOF'
import json, sys, datetime
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    if d.get("status") != "active":
        sys.exit(1)
    ts = datetime.datetime.strptime(d["updated_at"], "%Y-%m-%dT%H:%M:%SZ")
    ts = ts.replace(tzinfo=datetime.timezone.utc)
    age_h = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600
    sys.exit(0 if age_h < float(sys.argv[2]) else 1)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
PYEOF
}

# ─── wt_start: создать worktree сессии (идемпотентно) ───────────────────────
# Вывод (stdout): WORKTREE_PATH=<path> / BRANCH=<branch>. Диагностика → stderr.
wt_start() {
    local repo_root="$1"
    wt_load_config "$repo_root"

    if [ "$WT_ENABLED" != "true" ]; then
        echo "wt start: модуль выключен. Включить: {\"enabled\": true} в $repo_root/.claude/workflow-kit.json" >&2
        return 1
    fi
    if ! git -C "$repo_root" rev-parse --verify --quiet "refs/heads/${WT_BASE}" >/dev/null; then
        echo "wt start: базовая ветка '${WT_BASE}' не найдена. Задай \"base\" в .claude/workflow-kit.json." >&2
        return 1
    fi

    local full_sid="${CLAUDE_CODE_SESSION_ID:-}"
    if [ -z "$full_sid" ]; then
        full_sid="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 32)"
        [ -n "$full_sid" ] || full_sid="$(date +%Y%m%d%H%M%S)"
    fi
    local sid="${full_sid:0:8}"
    local branch="${WT_PREFIX}/${sid}"
    local wt_path="${repo_root}/${WT_DIR}/${sid}"

    # Каталог worktree'ов не должен светиться как untracked в главном checkout
    local excl
    excl="$(git -C "$repo_root" rev-parse --git-path info/exclude 2>/dev/null)"
    case "$excl" in /*) ;; *) excl="$repo_root/$excl" ;; esac
    if [ -n "$excl" ] && ! grep -qxF "/${WT_DIR}/" "$excl" 2>/dev/null; then
        mkdir -p "$(dirname "$excl")" 2>/dev/null
        printf '/%s/\n' "$WT_DIR" >>"$excl" 2>/dev/null || true
    fi

    # Manifest ДО создания ветки: параллельный GC не должен увидеть свежую ветку без живого manifest
    wt_write_manifest "$repo_root" "$sid" "$full_sid" "$branch" "$wt_path" "$WT_BASE" || true

    if ! wt_worktree_registered "$repo_root" "$wt_path"; then
        if git -C "$repo_root" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null; then
            git -C "$repo_root" worktree add "$wt_path" "$branch" >&2 || return 1
        else
            git -C "$repo_root" worktree add "$wt_path" -b "$branch" "$WT_BASE" >&2 || return 1
        fi
    fi

    # linkFiles: неотслеживаемые файлы главного checkout (например .env) — относительным симлинком
    local f src dst rel
    for f in ${WT_LINK_FILES[@]+"${WT_LINK_FILES[@]}"}; do
        f="${f%/}"
        src="$repo_root/$f"
        dst="$wt_path/$f"
        [ -e "$src" ] || continue
        [ -e "$dst" ] || [ -L "$dst" ] && continue
        mkdir -p "$(dirname "$dst")"
        rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$src" "$dst" 2>/dev/null)" || rel="$src"
        ln -s "$rel" "$dst"
    done

    echo "WORKTREE_PATH=$wt_path"
    echo "BRANCH=$branch"
}

# ─── wt_merge: влить ветку сессии в base (--no-ff) и убрать worktree ────────
# Параметры-флаги через переменные: WT_M_DRY WT_M_PUSH WT_M_CLEANUP WT_M_FORCE (true/false).
# Возврат: 0 = выполнено (или dry-run прошёл проверки), 1 = отказ с причиной.
wt_merge() {
    local repo_root="$1" base="$2" prefix="$3" sid_arg="${4:-}"
    local dry="${WT_M_DRY:-false}" push="${WT_M_PUSH:-false}" cleanup="${WT_M_CLEANUP:-false}" force="${WT_M_FORCE:-false}"

    local sid="" cur
    if [ -n "$sid_arg" ]; then
        sid="${sid_arg##*/}"
    else
        cur="$(git -C "$PWD" branch --show-current 2>/dev/null || true)"
        case "$cur" in
            "$prefix"/?*) sid="${cur#"$prefix"/}" ;;
        esac
        [ -z "$sid" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && sid="${CLAUDE_CODE_SESSION_ID:0:8}"
    fi
    if [ -z "$sid" ]; then
        echo "wt merge: не удалось определить сессию. Передай SID аргументом: wt merge <sid>" >&2
        return 1
    fi
    sid="${sid:0:8}"

    local branch="${prefix}/${sid}"
    if ! git -C "$repo_root" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null; then
        echo "wt merge: ветка ${branch} не найдена." >&2
        return 1
    fi
    if ! git -C "$repo_root" rev-parse --verify --quiet "refs/heads/${base}" >/dev/null; then
        echo "wt merge: базовая ветка '${base}' не найдена (ключ \"base\" в конфиге)." >&2
        return 1
    fi

    local wt_path unique
    wt_path="$(wt_find_worktree_path "$repo_root" "$branch")"
    [ -n "$wt_path" ] && [ ! -d "$wt_path" ] && wt_path=""
    unique="$(git -C "$repo_root" rev-list --count "${base}..${branch}" 2>/dev/null || echo 0)"

    local dirty=""
    [ -n "$wt_path" ] && dirty="$(wt_dirty_files "$wt_path")"

    # ── --cleanup-only: убрать worktree и ветку без слияния (с backup-ref) ──
    if $cleanup; then
        if [ -n "$dirty" ] && ! $force; then
            echo "wt merge --cleanup-only: в worktree незакоммиченные файлы (--force чтобы выбросить):" >&2
            printf '%s\n' "$dirty" >&2
            return 1
        fi
        if [ "$unique" -gt 0 ] && ! $force; then
            echo "wt merge --cleanup-only: в ${branch} ${unique} коммит(ов), которых нет в ${base}. Выбросить: добавь --force (ref останется в refs/wt-trash/)." >&2
            return 1
        fi
        if $dry; then
            echo "dry-run: удалил бы worktree ${wt_path:-(нет)} и ветку ${branch} (backup в refs/wt-trash/)"
            return 0
        fi
        git -C "$repo_root" update-ref "refs/wt-trash/$(date +%s)-${sid}" "$(git -C "$repo_root" rev-parse "$branch")"
        [ -n "$wt_path" ] && git -C "$repo_root" worktree remove --force "$wt_path"
        git -C "$repo_root" branch -D "$branch" >/dev/null
        wt_update_manifest_status "$repo_root" "$sid" "discarded"
        echo "ok: worktree и ветка ${branch} удалены (backup: refs/wt-trash/*-${sid})"
        echo "cd \"$repo_root\""
        return 0
    fi

    # ── проверки ──
    if [ -n "$dirty" ]; then
        echo "wt merge: отказ — в worktree незакоммиченные файлы. Закоммить свои файлы или выбрось правки:" >&2
        printf '%s\n' "$dirty" >&2
        return 1
    fi
    if [ "$unique" -eq 0 ]; then
        echo "wt merge: отказ — в ${branch} нет коммитов сверх ${base}. Убрать пустую сессию: wt merge ${sid} --cleanup-only" >&2
        return 1
    fi
    if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "wt merge: отказ — главный checkout ${repo_root} грязный (отслеживаемые файлы изменены). Сначала разберись с его правками:" >&2
        git -C "$repo_root" status --porcelain --untracked-files=no >&2
        return 1
    fi
    if [ -n "$WT_TEST_CMD" ] && [ -z "$wt_path" ]; then
        echo "wt merge: отказ — задан testCommand, а у ветки нет worktree, запустить тесты негде." >&2
        return 1
    fi

    if $dry; then
        echo "dry-run: проверки пройдены."
        [ -n "$WT_TEST_CMD" ] && echo "dry-run: запустил бы тесты в ${wt_path}: ${WT_TEST_CMD}"
        echo "dry-run: влил бы ${branch} (${unique} коммит(ов)) в ${base} через --no-ff, затем убрал worktree и ветку"
        $push && echo "dry-run: затем git push origin ${base}"
        return 0
    fi

    if [ -n "$WT_TEST_CMD" ]; then
        echo "→ тесты в ${wt_path}: ${WT_TEST_CMD}"
        if ! ( cd "$wt_path" && bash -c "$WT_TEST_CMD" ); then
            echo "wt merge: отказ — testCommand завершился с ошибкой, слияния нет." >&2
            return 1
        fi
    fi

    # ── синхронизация base с origin (если remote есть) ──
    local prev_branch
    prev_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    if [ "$prev_branch" != "$base" ]; then
        git -C "$repo_root" checkout -q "$base" || { echo "wt merge: не удалось переключить главный checkout на ${base}." >&2; return 1; }
    fi
    if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
        if git -C "$repo_root" fetch -q origin "$base" 2>/dev/null \
           && git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null; then
            if git -C "$repo_root" merge-base --is-ancestor "$base" "origin/${base}" 2>/dev/null; then
                git -C "$repo_root" merge -q --ff-only "origin/${base}" >/dev/null 2>&1 || true
            elif ! git -C "$repo_root" merge-base --is-ancestor "origin/${base}" "$base" 2>/dev/null; then
                echo "warn: ${base} разошёлся с origin/${base}; слияние идёт в локальный ${base}." >&2
            fi
        fi
    fi

    echo "→ merge ${branch} → ${base} (--no-ff)"
    if ! git -C "$repo_root" merge --no-ff "$branch" -m "merge: session ${sid} (${branch})"; then
        git -C "$repo_root" merge --abort 2>/dev/null || true
        [ -n "$prev_branch" ] && [ "$prev_branch" != "$base" ] && git -C "$repo_root" checkout -q "$prev_branch" 2>/dev/null
        echo "wt merge: конфликт, слияние отменено, ничего не удалено. Реши конфликт в worktree: git merge ${base}, затем повтори wt merge." >&2
        return 1
    fi
    echo "ok: слияние выполнено"

    [ -n "$wt_path" ] && git -C "$repo_root" worktree remove --force "$wt_path" && echo "ok: worktree удалён"
    git -C "$repo_root" branch -d "$branch" >/dev/null 2>&1 || git -C "$repo_root" branch -D "$branch" >/dev/null
    echo "ok: ветка ${branch} удалена"
    wt_update_manifest_status "$repo_root" "$sid" "merged"

    if $push; then
        if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
            git -C "$repo_root" push origin "$base" && echo "ok: push origin ${base}"
        else
            echo "warn: --push задан, но remote origin нет." >&2
        fi
    fi
    echo "cd \"$repo_root\""
    return 0
}

# ─── Возраст ветки (дней) ───────────────────────────────────────────────────
wt_branch_age_days() {
    local repo_root="$1" branch="$2" ts now
    ts="$(git -C "$repo_root" log -1 --format='%ct' "${branch}" 2>/dev/null)"
    [ -z "$ts" ] && { echo "?"; return; }
    now="$(date +%s)"
    echo $(( (now - ts) / 86400 ))
}

# ─── Влита ли ветка в base по содержимому (squash-safe, через git cherry) ───
# 0 = влита, 1 = есть невлитые коммиты, 2 = уникальных коммитов нет.
wt_branch_merged_into() {
    local repo_root="$1" branch="$2" base="$3" cherry
    cherry="$(git -C "$repo_root" cherry "$base" "$branch" 2>/dev/null)"
    [ -z "$cherry" ] && return 2
    if echo "$cherry" | grep -q '^+'; then
        return 1
    fi
    return 0
}

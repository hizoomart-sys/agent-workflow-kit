#!/usr/bin/env bash
# Tests for module "parallel sessions": wt start/merge/status/doctor, wt-lib classifier,
# PreToolUse guard (through guard-runner, command taken from hooks.json), session hooks.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WT="$ROOT/scripts/worktree/wt"
LIB="$ROOT/scripts/worktree/wt-lib.sh"
DOCTOR="$ROOT/scripts/worktree/wt-doctor.sh"
H_START="$ROOT/scripts/worktree/hooks/wt-session-start.sh"
H_STOP="$ROOT/scripts/worktree/hooks/wt-session-stop.sh"
H_GUARD="$ROOT/scripts/worktree/hooks/wt-pretooluse-guard.sh"
RUNNER="$ROOT/scripts/guards/guard-runner.sh"

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_eq() { # name expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (ожидалось '$2', факт '$3')"; fi
}
expect_contains() { # name needle haystack
    case "$3" in *"$2"*) ok "$1" ;; *) fail "$1 (нет '$2' в: $(printf '%s' "$3" | head -c 300))" ;; esac
}
expect_not_contains() {
    case "$3" in *"$2"*) fail "$1 (лишнее '$2')" ;; *) ok "$1" ;; esac
}
expect_true() { # name cmd...
    local n="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi
}
expect_false() {
    local n="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$n"; else ok "$n"; fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export WORKFLOW_KIT_HOME="$TMP/kit"
export GUARD_RUNNER_HOME="$TMP/kit"
export CLAUDE_PLUGIN_ROOT="$ROOT"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset CLAUDE_CODE_SESSION_ID WT_ALLOW_MAIN GUARD_PY

mkrepo() { # mkrepo <dir> [config-json]
    local d="$1" cfg="${2:-}"
    [ -n "$cfg" ] || cfg='{"enabled": true}'
    git init -q -b main "$d"
    echo ".claude/workflow-kit.json" >>"$d/.git/info/exclude"
    mkdir -p "$d/.claude"
    printf '%s\n' "$cfg" >"$d/.claude/workflow-kit.json"
    echo base >"$d/f.txt"
    git -C "$d" add f.txt
    git -C "$d" commit -qm init
}
commit_in() { # commit_in <dir> <file> [content]
    echo "${3:-work}" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -qm "add $2"
}

# ═══ 1. wt start ═══════════════════════════════════════════════════════════
echo "== 1. wt start"
R1="$TMP/r1"
mkrepo "$R1" '{"enabled": true, "linkFiles": [".env", "sub/secret.txt", "missing.txt"]}'
echo "KEY=1" >"$R1/.env"
mkdir -p "$R1/sub"; echo s >"$R1/sub/secret.txt"
echo ".env" >>"$R1/.git/info/exclude"; echo "sub/" >>"$R1/.git/info/exclude"

OUT="$(cd "$R1" && CLAUDE_CODE_SESSION_ID=abcd1234-ffff-0000 bash "$WT" start 2>&1)"; RC=$?
expect_eq "start: rc=0" 0 "$RC"
W1="$R1/.claude/worktrees/abcd1234"
expect_contains "start: печатает WORKTREE_PATH" "WORKTREE_PATH=$W1" "$OUT"
expect_true "start: worktree создан" test -d "$W1"
expect_eq "start: ветка claude/abcd1234" "claude/abcd1234" "$(git -C "$W1" branch --show-current)"
expect_eq "start: ветка от base" "$(git -C "$R1" rev-parse main)" "$(git -C "$W1" rev-parse HEAD)"
expect_true "start: manifest записан" test -f "$R1/.claude/worktrees/abcd1234.json"
expect_eq "start: manifest status=active" active "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$R1/.claude/worktrees/abcd1234.json")"
expect_true "linkFiles: .env симлинк" test -L "$W1/.env"
expect_eq "linkFiles: .env читается" "KEY=1" "$(cat "$W1/.env")"
expect_true "linkFiles: вложенный файл симлинк" test -L "$W1/sub/secret.txt"
expect_eq "linkFiles: вложенный читается" s "$(cat "$W1/sub/secret.txt")"
expect_false "linkFiles: отсутствующий файл пропущен" test -e "$W1/missing.txt"
expect_eq "главный checkout чист (worktreeDir в exclude)" "" "$(git -C "$R1" status --porcelain)"
OUT2="$(cd "$R1" && CLAUDE_CODE_SESSION_ID=abcd1234-ffff-0000 bash "$WT" start 2>&1)"; RC=$?
expect_eq "start: идемпотентен" 0 "$RC"
expect_contains "start: тот же путь" "WORKTREE_PATH=$W1" "$OUT2"

R1D="$TMP/r1d"
mkrepo "$R1D" '{"enabled": false}'
OUT="$(cd "$R1D" && CLAUDE_CODE_SESSION_ID=abcd1234 bash "$WT" start 2>&1)"; RC=$?
expect_eq "start при enabled:false → отказ" 1 "$RC"
expect_false "start при enabled:false: worktree не создан" test -d "$R1D/.claude/worktrees"

# ═══ 2. PreToolUse guard (через guard-runner, команда из hooks.json) ═══════
echo "== 2. guard"
WIRED_CMD="$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))
for grp in h["hooks"]["PreToolUse"]:
    for x in grp["hooks"]:
        if "wt-pretooluse-guard" in x["command"]:
            print(x["command"]); raise SystemExit(0)
raise SystemExit(1)' "$ROOT/hooks/hooks.json")" || { fail "guard не прописан в hooks.json"; WIRED_CMD=false; }
MATCHER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["matcher"])' "$ROOT/hooks/hooks.json")"
expect_eq "hooks.json: matcher" "Edit|Write|MultiEdit|NotebookEdit" "$MATCHER"

G="$TMP/g"; mkdir -p "$TMP/outside"
mkrepo "$G" '{"enabled": true, "enforce": "block"}'
git -C "$G" worktree add -q -b claude/wt1 "$G/.claude/worktrees/wt1"
git -C "$G" worktree add -q -b feature/x "$TMP/wt-feature"
git -C "$G" worktree add -q --detach "$TMP/wt-detached"
setcfg() { printf '{"enabled": %s, "enforce": "%s"}\n' "$1" "$2" >"$G/.claude/workflow-kit.json"; }
payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
grun() { # grun <cwd> <payload> → rc; out/err в $TMP/out|err
    ( cd "$1" && printf '%s' "$2" | eval "$WIRED_CMD" ) >"$TMP/out" 2>"$TMP/err"
    echo $?
}

expect_eq "guard deny: файл в главном checkout" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
expect_contains "guard: сообщение содержит путь и wt start" "$G" "$(cat "$TMP/err")"
expect_contains "guard: сообщение указывает wt start" "wt\" start" "$(cat "$TMP/err")"
expect_eq "guard deny: Write нового файла в главном" 2 "$(grun "$G" "$(payload Write "$G/new/dir/a.txt")")"
expect_eq "guard deny: NotebookEdit" 2 "$(grun "$G" '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$G"'/n.ipynb"}}')"
expect_eq "guard allow: файл внутри worktree" 0 "$(grun "$G/.claude/worktrees/wt1" "$(payload Edit "$G/.claude/worktrees/wt1/f.txt")")"
expect_eq "guard allow: Write нового файла в worktree" 0 "$(grun "$G/.claude/worktrees/wt1" "$(payload Write "$G/.claude/worktrees/wt1/sub/d/new.txt")")"
expect_eq "guard allow: cwd главный, файл в worktree" 0 "$(grun "$G" "$(payload Edit "$G/.claude/worktrees/wt1/f.txt")")"
expect_eq "guard n/a: инструмент Bash" 0 "$(grun "$G" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
expect_eq "guard allow: worktree с веткой не claude/*" 0 "$(grun "$TMP/wt-feature" "$(payload Edit "$TMP/wt-feature/f.txt")")"
expect_eq "guard allow: worktree с detached HEAD" 0 "$(grun "$TMP/wt-detached" "$(payload Edit "$TMP/wt-detached/f.txt")")"
git -C "$G" checkout -q -b claude/hotfix
expect_eq "guard deny: главный checkout на ветке claude/*" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
git -C "$G" checkout -q main
git -C "$G" checkout -q --detach
expect_eq "guard deny: главный checkout detached" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
git -C "$G" checkout -q main
expect_eq "guard allow: файл вне репозитория (cwd главный)" 0 "$(grun "$G" "$(payload Write "$TMP/outside/x.md")")"
expect_eq "guard deny: cwd вне репозитория, файл в главном" 2 "$(grun "$TMP/outside" "$(payload Edit "$G/f.txt")")"
expect_eq "guard deny: payload без file_path → по cwd" 2 "$(grun "$G" '{"tool_name":"Edit","tool_input":{}}')"

expect_eq "guard fail-closed: битый payload" 2 "$(grun "$G" 'не-json')"
expect_contains "guard: битый payload → GUARD_INTERNAL_ERROR" "GUARD_INTERNAL_ERROR" "$(cat "$TMP/err")"
RC="$( ( cd "$G" && printf '%s' "$(payload Edit "$G/f.txt")" | GUARD_PY=/nonexistent/python3 eval "$WIRED_CMD" ) >"$TMP/out" 2>"$TMP/err"; echo $? )"
expect_eq "guard fail-closed: нет python3" 2 "$RC"

echo '{' >"$G/.claude/workflow-kit.json"
expect_eq "guard fail-closed: битый конфиг" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
echo '{"enabled": true}' >"$G/.claude/workflow-kit.json"
expect_eq "guard: enforce по умолчанию = block" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"

setcfg true warn
expect_eq "guard warn: пропускает" 0 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
expect_contains "guard warn: additionalContext" "additionalContext" "$(cat "$TMP/out")"
setcfg false block
expect_eq "guard n/a: enabled=false" 0 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
rm -f "$G/.claude/workflow-kit.json"
expect_eq "guard n/a: нет конфига" 0 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
NG="$TMP/notgit"; mkdir -p "$NG"
expect_eq "guard n/a: не git-репозиторий" 0 "$(grun "$NG" "$(payload Edit "$NG/a.txt")")"
setcfg true block

RC="$( ( cd "$G" && printf '%s' "$(payload Edit "$G/f.txt")" | WT_ALLOW_MAIN=1 eval "$WIRED_CMD" ) >"$TMP/out" 2>"$TMP/err"; echo $? )"
expect_eq "guard allow: WT_ALLOW_MAIN=1" 0 "$RC"

mkdir -p "$GUARD_RUNNER_HOME/run/guard-bypass"
printf 'expires_at=%s\nreason=test\n' "$(( $(date +%s) + 300 ))" >"$GUARD_RUNNER_HOME/run/guard-bypass/worktree"
expect_eq "guard allow: активный файл обхода" 0 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
printf 'expires_at=%s\nreason=test\n' "$(( $(date +%s) - 5 ))" >"$GUARD_RUNNER_HOME/run/guard-bypass/worktree"
expect_eq "guard deny: просроченный обход" 2 "$(grun "$G" "$(payload Edit "$G/f.txt")")"
expect_false "guard: просроченный обход удалён" test -e "$GUARD_RUNNER_HOME/run/guard-bypass/worktree"

# падающий хук под раннером: fail-mode block → блок, warn → пропуск с диагностикой
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/crash.sh"; chmod +x "$TMP/crash.sh"
RC="$(printf '{}' | bash "$RUNNER" --name worktree --fail-mode block --timeout 5 -- "$TMP/crash.sh" >"$TMP/out" 2>"$TMP/err"; echo $?)"
expect_eq "runner block: падающий хук → exit 2" 2 "$RC"
expect_contains "runner block: GUARD_INTERNAL_ERROR" "GUARD_INTERNAL_ERROR" "$(cat "$TMP/err")"
RC="$(printf '{}' | bash "$RUNNER" --name worktree --fail-mode warn --timeout 5 -- "$TMP/crash.sh" >"$TMP/out" 2>"$TMP/err"; echo $?)"
expect_eq "runner warn: падающий хук → exit 0" 0 "$RC"
expect_contains "runner warn: диагностика в additionalContext" "GUARD_INTERNAL_ERROR" "$(cat "$TMP/out")"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$TMP/hang.sh"; chmod +x "$TMP/hang.sh"
RC="$(printf '{}' | bash "$RUNNER" --name worktree --fail-mode block --timeout 1 -- "$TMP/hang.sh" >"$TMP/out" 2>"$TMP/err"; echo $?)"
expect_eq "runner block: таймаут → exit 2" 2 "$RC"
expect_contains "runner: причина timeout" "timeout" "$(cat "$TMP/err")"

# ═══ 3. wt merge ═══════════════════════════════════════════════════════════
echo "== 3. wt merge"
M="$TMP/m"
mkrepo "$M"
sess() { # sess <sid8> → путь worktree
    ( cd "$M" && CLAUDE_CODE_SESSION_ID="$1" bash "$WT" start >/dev/null 2>&1 )
    echo "$M/.claude/worktrees/$1"
}
wtm() { ( cd "${MCWD:-$M}" && bash "$WT" merge "$@" ) >"$TMP/out" 2>&1; echo $?; }

W="$(sess aaaa1111)"
commit_in "$W" feature.txt
echo dirty >"$W/untracked.txt"
expect_eq "merge: грязный worktree → отказ" 1 "$(wtm aaaa1111)"
expect_contains "merge: отказ называет файл" "untracked.txt" "$(cat "$TMP/out")"
expect_true "merge: после отказа ветка жива" git -C "$M" rev-parse --verify -q refs/heads/claude/aaaa1111
rm -f "$W/untracked.txt"

printf 'x\n' >>"$M/f.txt"
expect_eq "merge: грязный главный checkout → отказ" 1 "$(wtm aaaa1111)"
expect_contains "merge: отказ про главный checkout" "главный checkout" "$(cat "$TMP/out")"
git -C "$M" checkout -q -- f.txt

BASE_BEFORE="$(git -C "$M" rev-parse main)"
expect_eq "merge --dry-run: rc=0" 0 "$(wtm aaaa1111 --dry-run)"
expect_contains "merge --dry-run: план" "dry-run" "$(cat "$TMP/out")"
expect_eq "dry-run: base не изменился" "$BASE_BEFORE" "$(git -C "$M" rev-parse main)"
expect_true "dry-run: worktree на месте" test -d "$W"
expect_true "dry-run: ветка на месте" git -C "$M" rev-parse --verify -q refs/heads/claude/aaaa1111

printf '{"enabled": true, "testCommand": "false"}\n' >"$M/.claude/workflow-kit.json"
expect_eq "merge: testCommand=false → отказ" 1 "$(wtm aaaa1111)"
expect_contains "merge: отказ из-за testCommand" "testCommand" "$(cat "$TMP/out")"
expect_eq "testCommand-отказ: base не изменился" "$BASE_BEFORE" "$(git -C "$M" rev-parse main)"
expect_true "testCommand-отказ: ветка жива" git -C "$M" rev-parse --verify -q refs/heads/claude/aaaa1111

printf '{"enabled": true, "testCommand": "test -f feature.txt"}\n' >"$M/.claude/workflow-kit.json"
RC="$(MCWD="$W" wtm)"
expect_eq "merge из worktree без SID (по ветке cwd), testCommand проходит" 0 "$RC"
expect_eq "merge: --no-ff создал merge-коммит (2 родителя)" 3 "$(git -C "$M" rev-list --parents -n1 main | wc -w | tr -d ' ')"
expect_eq "merge: тема merge-коммита" "merge: session aaaa1111 (claude/aaaa1111)" "$(git -C "$M" log -1 --format=%s main)"
expect_true "merge: файл попал в base" test -f "$M/feature.txt"
expect_false "merge: worktree удалён" test -d "$W"
expect_false "merge: ветка удалена" git -C "$M" rev-parse --verify -q refs/heads/claude/aaaa1111
expect_eq "merge: manifest merged" merged "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$M/.claude/worktrees/aaaa1111.json")"
printf '{"enabled": true}\n' >"$M/.claude/workflow-kit.json"

W="$(sess bbbb2222)"
expect_eq "merge: ветка без коммитов → отказ" 1 "$(wtm bbbb2222)"
expect_contains "merge: подсказка --cleanup-only" "cleanup-only" "$(cat "$TMP/out")"
expect_eq "cleanup-only --dry-run: rc=0" 0 "$(wtm bbbb2222 --cleanup-only --dry-run)"
expect_true "cleanup-only --dry-run: ничего не удалено" test -d "$W"
expect_eq "cleanup-only: пустая сессия убрана" 0 "$(wtm bbbb2222 --cleanup-only)"
expect_false "cleanup-only: worktree удалён" test -d "$W"
expect_false "cleanup-only: ветка удалена" git -C "$M" rev-parse --verify -q refs/heads/claude/bbbb2222

W="$(sess cccc3333)"; commit_in "$W" c.txt
expect_eq "cleanup-only с коммитами без --force → отказ" 1 "$(wtm cccc3333 --cleanup-only)"
expect_true "cleanup-only отказ: ветка жива" git -C "$M" rev-parse --verify -q refs/heads/claude/cccc3333
expect_eq "cleanup-only --force" 0 "$(wtm cccc3333 --cleanup-only --force)"
expect_eq "cleanup-only --force: backup-ref создан" 1 "$(git -C "$M" for-each-ref 'refs/wt-trash/*-cccc3333' | wc -l | tr -d ' ')"

# конфликт: слияние откатывается, ничего не удалено
W="$(sess dddd4444)"; echo one >"$W/f.txt"; git -C "$W" commit -qam one
echo two >"$M/f.txt"; git -C "$M" commit -qam two
expect_eq "merge: конфликт → отказ" 1 "$(wtm dddd4444)"
expect_true "конфликт: ветка и worktree живы" test -d "$W"
expect_eq "конфликт: главный checkout без MERGE_HEAD" "" "$(git -C "$M" rev-parse -q --verify MERGE_HEAD || true)"
wtm dddd4444 --cleanup-only --force >/dev/null

# push в remote
BARE="$TMP/origin.git"; git init -q --bare -b main "$BARE"
git -C "$M" remote add origin "$BARE"; git -C "$M" push -q origin main
W="$(sess eeee5555)"; commit_in "$W" p.txt
expect_eq "merge --push" 0 "$(wtm eeee5555 --push)"
expect_eq "merge --push: remote получил base" "$(git -C "$M" rev-parse main)" "$(git -C "$BARE" rev-parse main)"
W="$(sess ffff6666)"; commit_in "$W" q.txt
expect_eq "merge без --push" 0 "$(wtm ffff6666)"
expect_false "без --push remote не обновлён" test "$(git -C "$M" rev-parse main)" = "$(git -C "$BARE" rev-parse main)"

# ═══ 4. session hooks ══════════════════════════════════════════════════════
echo "== 4. hooks"
S="$TMP/s"
mkrepo "$S"
SW="$(cd "$S" && CLAUDE_CODE_SESSION_ID=5555aaaa-0000 bash "$WT" start 2>/dev/null | sed -n 's/^WORKTREE_PATH=//p')"
commit_in "$SW" s.txt
hp() { printf '{"session_id":"5555aaaa-0000","cwd":"%s"}' "$1"; }

OUT="$(hp "$SW" | bash "$H_STOP")"; RC=$?
expect_eq "stop: rc=0" 0 "$RC"
expect_contains "stop: предлагает wt merge" "merge 5555aaaa" "$OUT"
expect_contains "stop: называет файл" "s.txt" "$OUT"
OUT="$(hp "$SW" | bash "$H_STOP")"
expect_eq "stop: повтор на том же состоянии молчит" "" "$OUT"
commit_in "$SW" s2.txt
OUT="$(hp "$SW" | bash "$H_STOP")"
expect_contains "stop: новое состояние снова напоминает" "merge 5555aaaa" "$OUT"
OUT="$(hp "$S" | bash "$H_STOP")"; RC=$?
expect_eq "stop на base: молчит" "" "$OUT"; expect_eq "stop на base: rc=0" 0 "$RC"
OUT="$(printf '{"cwd":"%s"}' "$TMP/notgit" | bash "$H_STOP")"; RC=$?
expect_eq "stop вне git: молчит, rc=0" "0:" "$RC:$OUT"
S2="$TMP/s2"; mkrepo "$S2" '{"enabled": false}'; git -C "$S2" checkout -q -b claude/zzzz9999; commit_in "$S2" a.txt
OUT="$(printf '{"cwd":"%s"}' "$S2" | bash "$H_STOP")"
expect_eq "stop при enabled:false: молчит" "" "$OUT"
S3="$TMP/s3"; mkrepo "$S3"
SW3="$(cd "$S3" && CLAUDE_CODE_SESSION_ID=7777bbbb bash "$WT" start 2>/dev/null | sed -n 's/^WORKTREE_PATH=//p')"
OUT="$(printf '{"session_id":"7777bbbb","cwd":"%s"}' "$SW3" | bash "$H_STOP")"
expect_eq "stop: сессия без работы молчит" "" "$OUT"

OUT="$(hp "$S" | bash "$H_START")"; RC=$?
expect_eq "session-start в главном: rc=0" 0 "$RC"
CTX="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
expect_contains "session-start в главном: инструкция wt start" "wt\" start" "$CTX"
expect_contains "session-start: формат SessionStart" '"hookEventName": "SessionStart"' "$OUT"
OUT="$(hp "$SW" | bash "$H_START")"
expect_eq "session-start в worktree: молчит" "" "$OUT"
OUT="$(printf '{"cwd":"%s"}' "$TMP/notgit" | bash "$H_START")"; RC=$?
expect_eq "session-start вне git: молчит, rc=0" "0:" "$RC:$OUT"
OUT="$(printf '{"cwd":"%s"}' "$S2" | bash "$H_START")"
expect_eq "session-start при enabled:false: молчит" "" "$OUT"
OUT="$(printf 'не-json' | bash "$H_START")"; RC=$?
expect_eq "session-start: битый stdin, rc=0" 0 "$RC"

# ═══ 5. wt-doctor / классификатор ══════════════════════════════════════════
echo "== 5. doctor + классификатор"
# shellcheck source=/dev/null
source "$LIB"
D="$TMP/d"
mkrepo "$D"
git -C "$D" worktree add -q "$D/wt-empty" -b claude/empty main
expect_eq "classify: свежая сессия = ACTIVE_EMPTY" ACTIVE_EMPTY "$(wt_classify_branch "$D" claude/empty main)"
echo draft >"$D/wt-empty/draft.txt"
expect_eq "classify: незакоммиченное = ACTIVE_DIRTY" ACTIVE_DIRTY "$(wt_classify_branch "$D" claude/empty main)"
rm -f "$D/wt-empty/draft.txt"
git -C "$D" worktree add -q "$D/wt-work" -b claude/work main
commit_in "$D/wt-work" w.txt
expect_eq "classify: сессия с коммитом = ACTIVE_CLEAN" ACTIVE_CLEAN "$(wt_classify_branch "$D" claude/work main)"
git -C "$D" branch claude/orphan main
expect_eq "classify: хвост без worktree = TREE_IDENTICAL_SAFE" TREE_IDENTICAL_SAFE "$(wt_classify_branch "$D" claude/orphan main)"
for br in claude/empty claude/work; do
    case "$(wt_classify_branch "$D" "$br" main)" in
        *_SAFE) fail "инвариант: $br с живым worktree помечен _SAFE" ;;
        ACTIVE_*) ok "инвариант: $br ACTIVE_*" ;;
        *) fail "инвариант: $br неизвестная категория" ;;
    esac
done

# --gc на влитой stale-ветке (без worktree)
git -C "$D" checkout -q -b claude/stale main
commit_in "$D" stale.txt
git -C "$D" checkout -q main
git -C "$D" merge -q --no-ff claude/stale -m "merge stale"
STALE_SHA="$(git -C "$D" rev-parse claude/stale)"
# просроченный и свежий бэкапы для проверки TTL от времени удаления
OLD_C="$(date -u -v-45d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '45 days ago' '+%Y-%m-%dT%H:%M:%S')"
NOW="$(date +%s)"
git -C "$D" update-ref "refs/wt-trash/${NOW}-fresh" "$STALE_SHA"
git -C "$D" update-ref "refs/wt-trash/$(( NOW - 40*86400 ))-old" "$STALE_SHA"
git -C "$D" update-ref "refs/wt-trash/legacy" "$STALE_SHA"
OUT="$(cd "$D" && bash "$WT" doctor 2>&1)"
expect_contains "doctor (без --gc) показывает таблицу" "claude/stale" "$OUT"
expect_true "doctor без --gc: ветка не тронута" git -C "$D" rev-parse --verify -q refs/heads/claude/stale
OUT="$(cd "$D" && bash "$WT" doctor --gc 2>&1)"; RC=$?
expect_eq "doctor --gc: rc=0" 0 "$RC"
expect_false "gc: stale-ветка удалена" git -C "$D" rev-parse --verify -q refs/heads/claude/stale
BK="$(git -C "$D" for-each-ref --format='%(refname)' 'refs/wt-trash/*-stale')"
expect_true "gc: backup-ref refs/wt-trash/*-stale создан" test -n "$BK"
expect_eq "gc: backup указывает на старый tip" "$STALE_SHA" "$(git -C "$D" rev-parse "$BK")"
git -C "$D" branch restored "$BK"
expect_eq "gc: ветка восстановима из backup" "$STALE_SHA" "$(git -C "$D" rev-parse restored)"
expect_true "gc: живая пустая сессия не тронута" git -C "$D" rev-parse --verify -q refs/heads/claude/empty
expect_true "gc: живая сессия с коммитом не тронута" git -C "$D" rev-parse --verify -q refs/heads/claude/work
expect_false "gc: хвост claude/orphan убран" git -C "$D" rev-parse --verify -q refs/heads/claude/orphan
expect_true "gc/TTL: свежий бэкап выжил" git -C "$D" rev-parse --verify -q "refs/wt-trash/${NOW}-fresh"
expect_false "gc/TTL: просроченный бэкап удалён" git -C "$D" rev-parse --verify -q "refs/wt-trash/$(( NOW - 40*86400 ))-old"
expect_true "gc/TTL: ref без метки не тронут" git -C "$D" rev-parse --verify -q refs/wt-trash/legacy

# живая чужая сессия по manifest: безопасная по git-фактам ветка без worktree не удаляется, пока manifest свежий
git -C "$D" branch claude/livetail main
wt_load_config "$D"
wt_write_manifest "$D" livetail livetail-full claude/livetail "$D/none" main
OUT="$(cd "$D" && bash "$WT" doctor --gc 2>&1)"
expect_contains "gc: живой manifest → SKIP" "живая сессия" "$OUT"
expect_true "gc: ветка с живым manifest жива" git -C "$D" rev-parse --verify -q refs/heads/claude/livetail

# gc не трогает origin
BARE2="$TMP/origin2.git"; git init -q --bare -b main "$BARE2"
git -C "$D" remote add origin "$BARE2"
git -C "$D" branch claude/remt main; git -C "$D" push -q origin claude/remt
cd "$D" && bash "$WT" doctor --gc >/dev/null 2>&1; cd "$HERE"
expect_true "gc: удалённая ветка не удаляется" git -C "$BARE2" rev-parse --verify -q refs/heads/claude/remt

echo
if [ "$FAILS" -eq 0 ]; then echo "ИТОГ: PASS"; else echo "ИТОГ: FAIL ($FAILS)"; fi
exit "$FAILS"

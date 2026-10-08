#!/usr/bin/env bash
# Tests for wiring-health.py: healthy -> silent; missing script / loud barrier -> warning.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WH="$HERE/../scripts/guards/wiring-health.py"
FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AWK_FIRE_LOG="$TMP/fires.jsonl"
export GUARD_RUNNER_HOME="$TMP/home"
unset AWK_HOOKS_JSON

OUT="$(python3 "$WH")"
[ -z "$OUT" ] && ok "healthy: silent" || fail "healthy: expected silence, got: $OUT"

cat > "$TMP/hooks.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}\"/scripts/guards/does-not-exist.js"}]}]}}
EOF
OUT="$(AWK_HOOKS_JSON="$TMP/hooks.json" python3 "$WH")"
case "$OUT" in
    *additionalContext*does-not-exist.js*) ok "missing script: warning" ;;
    *) fail "missing script: expected warning, got: $OUT" ;;
esac
printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' && ok "warning is valid JSON" || fail "warning is not valid JSON"

printf '{bad json' > "$TMP/broken.json"
OUT="$(AWK_HOOKS_JSON="$TMP/broken.json" python3 "$WH")"
case "$OUT" in *unreadable*) ok "broken hooks.json: warning" ;; *) fail "broken hooks.json: got: $OUT" ;; esac

python3 - "$AWK_FIRE_LOG" <<'EOF'
import json, sys
from datetime import datetime, timezone
ts = datetime.now(timezone.utc).isoformat()
with open(sys.argv[1], "w") as f:
    for _ in range(200):
        f.write(json.dumps({"ts": ts, "guard": "noisy-guard", "action": "block"}) + "\n")
EOF
OUT="$(python3 "$WH")"
case "$OUT" in *"loud barrier: noisy-guard"*) ok "loud barrier: warning" ;; *) fail "loud barrier: got: $OUT" ;; esac

# python3 missing from PATH of the checker is not testable portably; interpreters check covered by healthy run.
[ "$FAILS" -eq 0 ] && { echo "ALL OK"; exit 0; }
echo "$FAILS FAILED"
exit 1

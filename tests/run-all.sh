#!/usr/bin/env bash
# Runs every test in this directory; exits non-zero if any fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=()
for t in "$HERE"/test-*; do
    case "$t" in
        *.sh)  runner=(bash) ;;
        *.py)  runner=(python3) ;;
        *.mjs) runner=(node) ;;
        *) continue ;;
    esac
    echo "=== $(basename "$t")"
    "${runner[@]}" "$t" || FAILED+=("$(basename "$t")")
done
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILED: ${FAILED[*]}"
    exit 1
fi
echo "ALL TESTS PASSED"

#!/usr/bin/env bash
# destructive-git-guard.sh — PreToolUse (Bash): block destructive git commands (exit 2).
# Judges the ACTION (parsed shell command), not the spelling of the string.
# Wire it through guard-runner.sh with --fail-mode block.
exec node "$(dirname "$0")/lib/git-destructive-verdict.js"

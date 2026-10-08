#!/usr/bin/env python3
"""wiring-health.py — SessionStart: quiet unless the kit's own wiring is broken.

Checks:
  1. every script referenced in the plugin's hooks.json exists and is readable;
  2. required interpreters (node, python3, git) are on PATH;
  3. (optional) no barrier fired >= LOUD_THRESHOLD times in the last 14 days
     ("loud barrier": a signal about behaviour or a too-broad rule, not about the barrier).

Problems -> hookSpecificOutput.additionalContext. Healthy -> prints nothing.
Any internal oddity -> exit 0 silently. Overrides (tests): AWK_HOOKS_JSON, AWK_FIRE_LOG.
"""
import json
import os
import re
import shutil
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOKS_JSON = Path(os.environ.get("AWK_HOOKS_JSON") or ROOT / "hooks" / "hooks.json")
KIT_HOME = Path(os.environ.get("GUARD_RUNNER_HOME") or Path.home() / ".claude" / "workflow-kit")
FIRE_LOG = Path(os.environ.get("AWK_FIRE_LOG") or KIT_HOME / "telemetry" / "guard-fires.jsonl")
LOUD_THRESHOLD = 200
WINDOW_DAYS = 14
INTERPRETERS = ("node", "python3", "git")
SCRIPT_RE = re.compile(r'\$\{CLAUDE_PLUGIN_ROOT\}"?(/[^\s"\']+)')


def referenced_scripts(data):
    found = []
    for groups in (data.get("hooks") or {}).values():
        for group in groups:
            for hook in group.get("hooks", []):
                found += SCRIPT_RE.findall(hook.get("command", ""))
    return sorted(set(found))


def check_scripts():
    try:
        data = json.loads(HOOKS_JSON.read_text(encoding="utf-8"))
    except Exception as e:
        return [f"hooks.json unreadable ({HOOKS_JSON.name}: {e.__class__.__name__})"]
    problems = []
    for rel in referenced_scripts(data):
        p = ROOT / rel.lstrip("/")
        if not p.is_file():
            problems.append(f"hook script missing: {rel}")
        elif not os.access(p, os.R_OK):
            problems.append(f"hook script not readable: {rel}")
    return problems


def check_interpreters():
    return [f"required interpreter not on PATH: {b}" for b in INTERPRETERS if not shutil.which(b)]


def check_loud():
    if not FIRE_LOG.is_file():
        return []
    since = datetime.now(timezone.utc) - timedelta(days=WINDOW_DAYS)
    counts = {}
    for line in FIRE_LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            r = json.loads(line)
            if datetime.fromisoformat(r["ts"].replace("Z", "+00:00")) >= since:
                counts[r["guard"]] = counts.get(r["guard"], 0) + 1
        except Exception:
            continue
    return [f"loud barrier: {g} fired {n} times in {WINDOW_DAYS} days (rule too broad, or behaviour to fix)"
            for g, n in sorted(counts.items()) if n >= LOUD_THRESHOLD]


def main():
    problems = []
    for check in (check_scripts, check_interpreters, check_loud):
        try:
            problems += check()
        except Exception:
            continue
    if not problems:
        return
    msg = "agent-workflow-kit wiring-health: " + "; ".join(problems)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}},
                     ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)

#!/usr/bin/env python3
"""Tests for save-session-silence-guard.js: synthetic JSONL transcripts only."""
import json
import os
import subprocess
import sys
import tempfile

D = tempfile.mkdtemp()
HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "scripts", "guards", "save-session-silence-guard.js")
ENV = {**os.environ, "AWK_FIRE_LOG": os.path.join(D, "fires.jsonl")}
MARKER = "⟦save-session: конец вывода — ничего больше не печатать⟧"
FENCE = "```\nпродолжаем тема сессии\n```"


def u(text): return {"type": "user", "message": {"role": "user", "content": text}}
def meta(): return {"type": "user", "isMeta": True, "message": {"role": "user", "content": "Stop hook feedback"}}
def say(text): return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
def call(cmd, tid="s1"): return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}}
def result(text, tid="s1"): return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}}


SAVE = call("python3 scripts/session/save-session.py --body b.md")
OUT = result("card\n" + MARKER)

cases = {
    "marker_fence_only": ([u("save"), SAVE, OUT, say(FENCE)], 0, False),
    "marker_nothing": ([u("save"), SAVE, OUT], 0, False),
    "marker_fence_prose": ([u("save"), SAVE, OUT, say(FENCE), say("Saved, next we will fix the tests.")], 2, False),
    "marker_prose": ([u("save"), SAVE, OUT, say("Session saved, here is a recap.")], 2, False),
    "no_save_call": ([u("hi"), call("ls"), result("a\n" + MARKER, "s1"), say("Here is some prose.")], 0, False),
    "stop_hook_active": ([u("save"), SAVE, OUT, say("prose after marker")], 0, True),
    "meta_keeps_turn": ([u("save"), SAVE, OUT, say("prose after marker"), meta(), say("more prose")], 2, False),
    "read_script_source": ([u("show"), call("cat scripts/session/save-session.py", "s2"),
                            result('print("' + "⟦save-session: конец вывода⟧" + '")', "s2"), say("That is the source.")], 0, False),
}

fails = 0
for name, (msgs, want, active) in cases.items():
    p = os.path.join(D, f"sg-{name}.jsonl")
    with open(p, "w") as f:
        for m in msgs:
            f.write(json.dumps(m, ensure_ascii=False) + "\n")
    payload = {"transcript_path": p, "session_id": "test"}
    if active:
        payload["stop_hook_active"] = True
    r = subprocess.run(["node", HOOK], input=json.dumps(payload), capture_output=True, text=True, env=ENV)
    ok = r.returncode == want
    fails += not ok
    print(("ok  " if ok else "FAIL"), name, "exit", r.returncode, "want", want, (r.stderr[:50].replace("\n", " ") if r.returncode else ""))

sys.exit(1 if fails else 0)

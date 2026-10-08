#!/usr/bin/env python3
"""Tests for verify-before-stop.js: synthetic JSONL transcripts only."""
import json
import os
import subprocess
import sys
import tempfile

D = tempfile.mkdtemp()
HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "scripts", "guards", "verify-before-stop.js")
ENV = {**os.environ, "AWK_FIRE_LOG": os.path.join(D, "fires.jsonl")}


def u(text): return {"type": "user", "message": {"role": "user", "content": text}}
def tr(): return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}}
def meta(): return {"type": "user", "isMeta": True, "message": {"role": "user", "content": "Stop hook feedback"}}
def tool(name): return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": name, "input": {}}]}}
def say(text): return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


cases = {
    "edit_then_claim": ([u("fix it"), tool("Edit"), tr(), say("Готово, исправлено.")], 2),
    "edit_verify_claim": ([u("fix it"), tool("Edit"), tr(), tool("Bash"), tr(), say("Готово.")], 0),
    "verify_before_edit": ([u("fix it"), tool("Bash"), tr(), tool("Edit"), tr(), say("Исправлено.")], 2),
    "no_edit_claim": ([u("check"), tool("Bash"), tr(), say("Всё работает.")], 0),
    "edit_prev_turn": ([u("a"), tool("Edit"), tr(), say("edited"), u("b"), say("Готово.")], 0),
    "edit_no_claim": ([u("fix it"), tool("Edit"), tr(), say("Changed the line, please check.")], 0),
    "english_claim": ([u("fix it"), tool("Write"), tr(), say("All done, it works.")], 2),
    "ru_neg_not_working": ([u("fix"), tool("Edit"), tr(), say("Тест пока не работает.")], 0),
    "ru_neg_not_ready": ([u("fix"), tool("Edit"), tr(), say("Ещё не готово.")], 0),
    "en_neg_not_done": ([u("fix"), tool("Edit"), tr(), say("Not done yet.")], 0),
    "en_neg_isnt_working": ([u("fix"), tool("Edit"), tr(), say("It isn't working.")], 0),
    "en_neg_not_fixed": ([u("fix"), tool("Edit"), tr(), say("Not fixed.")], 0),
    "substring_abandoned": ([u("fix"), tool("Edit"), tr(), say("The attempt was abandoned.")], 0),
    "pos_fixed": ([u("fix"), tool("Edit"), tr(), say("Fixed.")], 2),
    "pos_after_neg_clause": ([u("fix"), tool("Edit"), tr(), say("Не знаю, готово.")], 2),
    "notebook_edit_claim": ([u("fix"), tool("NotebookEdit"), tr(), say("Готово.")], 2),
    "meta_feedback_keeps_turn": ([u("fix it"), tool("Edit"), tr(), say("Done."), meta(), say("Done again.")], 2),
}

fails = 0
for name, (msgs, want) in cases.items():
    p = os.path.join(D, f"vbs-{name}.jsonl")
    with open(p, "w") as f:
        for m in msgs:
            f.write(json.dumps(m, ensure_ascii=False) + "\n")
    r = subprocess.run(["node", HOOK], input=json.dumps({"transcript_path": p, "session_id": "test"}),
                       capture_output=True, text=True, env=ENV)
    ok = r.returncode == want
    fails += not ok
    print(("ok  " if ok else "FAIL"), name, "exit", r.returncode, "want", want, (r.stderr[:50].replace("\n", " ") if r.returncode else ""))

r = subprocess.run(["node", HOOK], input=json.dumps({"transcript_path": os.path.join(D, "vbs-edit_then_claim.jsonl"), "stop_hook_active": True}),
                   capture_output=True, text=True, env=ENV)
ok = r.returncode == 0
fails += not ok
print(("ok  " if ok else "FAIL"), "stop_hook_active", "exit", r.returncode, "want", 0)

sys.exit(1 if fails else 0)

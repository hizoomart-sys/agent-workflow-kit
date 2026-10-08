#!/usr/bin/env node
// Stop hook: blocks the turn if Claude printed prose AFTER save-session.py's final marker
// in the same turn. Allowed after the marker: exactly one fenced code block whose body
// starts with «продолжаем» (the user does not see tool output, so Claude prints the fence).
//
// Why a hook and not a rule: the marker is just text the script prints, the same
// "please don't" that gets ignored. Printing an instruction is not enforcing it.
//
// Exit 2 = block; the reason goes to stderr (the harness hands the model only stderr).

const fs = require('fs');
const { logFire } = require('./lib/fire-log.js');

const MARKER = 'save-session: конец вывода';
// The marker only counts when it comes back from a tool_use that actually invoked the
// script. Prose or a file that merely quotes the marker cannot fake that.
const INVOCATION = /save-session\.py/;
const FENCE_ONLY = /^```[^\n]*\n\s*продолжаем\s[\s\S]*?```$/;

let raw = '';
process.stdin.setEncoding('utf-8');
process.stdin.on('data', chunk => (raw += chunk));
process.stdin.on('end', () => {
  let input = {};
  try { input = JSON.parse(raw); } catch { process.exit(0); }

  // Already blocked once this turn: do not loop.
  if (input.stop_hook_active) process.exit(0);

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);

  let messages = [];
  try {
    const stat = fs.statSync(transcriptPath);
    const MAX_FULL = 256 * 1024;
    const TAIL = 128 * 1024;
    let buf;
    if (stat.size <= MAX_FULL) {
      buf = fs.readFileSync(transcriptPath, 'utf-8').trim();
    } else {
      const fd = fs.openSync(transcriptPath, 'r');
      const b = Buffer.alloc(TAIL);
      fs.readSync(fd, b, 0, TAIL, stat.size - TAIL);
      fs.closeSync(fd);
      buf = b.toString('utf-8').replace(/^[^\n]*\n/, '').trim();
    }
    messages = buf.split('\n').filter(Boolean).map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean);
  } catch { process.exit(0); }

  // Walk back to the last genuine user message: everything after it is "this turn".
  let turnStart = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m || m.type !== 'user') continue;
    // Not real user input: meta records (hook feedback, system notices; content is a
    // STRING with isMeta:true) and tool results (content = [{type:'tool_result'}]).
    if (m.isMeta) continue;
    const c = m.message && m.message.content;
    if (Array.isArray(c) && c.some(b => b && b.type === 'tool_result')) continue;
    turnStart = i;
    break;
  }

  const turn = messages.slice(turnStart);

  // tool_use ids of calls that actually ran save-session.py this turn.
  const invocationIds = new Set();
  for (const m of turn) {
    if (!m || m.type !== 'assistant') continue;
    const c = m.message && m.message.content;
    if (!Array.isArray(c)) continue;
    for (const block of c) {
      if (!block || block.type !== 'tool_use' || !block.id) continue;
      let inp = '';
      try { inp = JSON.stringify(block.input || {}); } catch { continue; }
      if (INVOCATION.test(inp)) invocationIds.add(block.id);
    }
  }
  if (invocationIds.size === 0) process.exit(0);

  // Marker in the RESULT OF THAT CALL, line-anchored (reading the script source also
  // matches INVOCATION, but there the marker sits inside print("...")).
  let markerIdx = -1;
  for (let i = 0; i < turn.length; i++) {
    const c = turn[i] && turn[i].message && turn[i].message.content;
    if (!Array.isArray(c)) continue;
    for (const block of c) {
      if (!block || block.type !== 'tool_result') continue;
      if (!invocationIds.has(block.tool_use_id)) continue;
      const content = block.content;
      let text = '';
      if (typeof content === 'string') text = content;
      else if (Array.isArray(content)) text = content.map(x => (x && x.text) || '').join('');
      if (text.split('\n').some(l => l.trim().startsWith('⟦' + MARKER))) markerIdx = i;
    }
  }
  if (markerIdx === -1) process.exit(0);

  const offending = [];
  for (let i = markerIdx + 1; i < turn.length; i++) {
    const m = turn[i];
    if (!m || m.type !== 'assistant') continue;
    const c = m.message && m.message.content;
    if (!Array.isArray(c)) continue;
    for (const block of c) {
      if (!block || block.type !== 'text') continue;
      const t = (block.text || '').trim();
      if (!t) continue;
      if (FENCE_ONLY.test(t)) continue;
      offending.push(t.slice(0, 120));
    }
  }

  if (offending.length > 0) {
    logFire('save-session-silence-guard', 'block', 'prose-after-marker', input.session_id);
    process.stderr.write(
      'BLOCKED: prose after the save-session final marker:\n' +
      offending.map(t => '  -> "' + t + '..."').join('\n') + '\n\n' +
      'After the marker exactly ONE artifact is allowed: a code block starting with «продолжаем ...» ' +
      '(the user does not see script output, so you print the fence). Anything else (recap of the card, ' +
      'status, "next we will...") is not allowed.\n' +
      'ACTION: keep only the «продолжаем» fence (or nothing) and end the turn.\n'
    );
    process.exit(2);
  }

  process.exit(0);
});

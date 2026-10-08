#!/usr/bin/env node
// Stop hook: blocks "done/fixed/works" claims made after Write/Edit without any verification.
// Exit 2 = block Claude's response and send stderr back as feedback (Claude must continue).

const fs = require('fs');
const { logFire } = require('./lib/fire-log.js');

const SUCCESS_RU = [
  'готово', 'исправлено', 'исправил', 'работает', 'обновлено', 'обновил',
  'всё работает', 'все работает', 'починено', 'починил', 'запущено',
  'выполнено', 'сделано', 'завершено', 'теперь работает', 'уже работает',
];
const SUCCESS_EN = [
  'done', 'fixed', 'works', 'working', 'updated', 'completed', 'finished',
  "it's working", 'now works', 'is working', 'deployed', 'applied',
];
const SUCCESS_WORDS = [...SUCCESS_RU, ...SUCCESS_EN];

const NEGATIONS = new Set([
  'не', 'без', 'not', "isn't", 'isnt', "aren't", "wasn't", "weren't", 'never',
  "doesn't", "didn't", "don't", "hasn't", "haven't",
]);
const WORD_RES = SUCCESS_WORDS.map(w => new RegExp(
  '(?<![\\p{L}\\p{N}])' + w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ /g, '\\s+') + '(?![\\p{L}\\p{N}])', 'giu'));

// A success word counts unless one of the 2 words before it (same clause) is a negation.
function hasSuccessClaim(text) {
  const t = text.toLowerCase().replace(/\u2019/g, "'");
  for (const re of WORD_RES) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(t))) {
      const clause = t.slice(0, m.index).split(/[.!?;:,\n]/).pop();
      const prev = (clause.match(/[\p{L}\p{N}']+/gu) || []).slice(-2);
      if (!prev.some(x => NEGATIONS.has(x))) return true;
    }
  }
  return false;
}

const CHANGE_TOOLS = ['Write', 'Edit', 'MultiEdit', 'NotebookEdit'];
const VERIFY_TOOLS = ['Bash', 'Read', 'Grep', 'Glob'];

let raw = '';
process.stdin.setEncoding('utf-8');
process.stdin.on('data', chunk => (raw += chunk));
process.stdin.on('end', () => {
  let input = {};
  try { input = JSON.parse(raw); } catch { process.exit(0); }

  // Prevent infinite loop: if we already blocked once, don't block again
  if (input.stop_hook_active) process.exit(0);

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);

  // Avoid parsing the whole transcript on every Stop (it grows over a session).
  // Small files: read whole. Large files: read only the tail, which holds the current turn.
  let messages = [];
  try {
    const stat = fs.statSync(transcriptPath);
    const MAX_FULL = 256 * 1024; // <=256KB: cheap to read whole
    const TAIL = 64 * 1024;      // >256KB: last 64KB is plenty for the last message
    let raw;
    if (stat.size <= MAX_FULL) {
      raw = fs.readFileSync(transcriptPath, 'utf-8').trim();
    } else {
      const fd = fs.openSync(transcriptPath, 'r');
      const buf = Buffer.alloc(TAIL);
      fs.readSync(fd, buf, 0, TAIL, stat.size - TAIL);
      fs.closeSync(fd);
      // Drop the leading partial line so JSON.parse doesn't choke on it.
      raw = buf.toString('utf-8').replace(/^[^\n]*\n/, '').trim();
    }
    // Handle both JSON array and JSONL formats
    if (raw.startsWith('[')) {
      messages = JSON.parse(raw);
    } else {
      messages = raw.split('\n').filter(Boolean).map(line => {
        try { return JSON.parse(line); } catch { return null; }
      }).filter(Boolean);
    }
  } catch { process.exit(0); }

  // Transcript JSONL: one line per content block, {type:'assistant'|'user', message:{content}}.
  // Legacy array format: {role, content}. Normalize both to {role, content, meta}.
  const norm = messages.map(m => ({
    role: m.role || m.type,
    content: (m.message && m.message.content !== undefined) ? m.message.content : m.content,
    meta: !!m.isMeta,
  }));

  // The current turn starts after the last real user prompt (not a tool_result, not hook feedback).
  const isPrompt = m => m.role === 'user' && !m.meta && (
    typeof m.content === 'string' ||
    (Array.isArray(m.content) && m.content.some(b => b.type === 'text'))
  );
  let start = 0;
  for (let i = norm.length - 1; i >= 0; i--) {
    if (isPrompt(norm[i])) { start = i + 1; break; }
  }

  const blocks = [];
  for (const m of norm.slice(start)) {
    if (m.role === 'assistant' && Array.isArray(m.content)) blocks.push(...m.content);
  }
  if (!blocks.length) process.exit(0);

  let lastChange = -1;
  blocks.forEach((b, i) => { if (b.type === 'tool_use' && CHANGE_TOOLS.includes(b.name)) lastChange = i; });
  const hasChanges = lastChange >= 0;
  const hasVerification = blocks.some((b, i) => i > lastChange && b.type === 'tool_use' && VERIFY_TOOLS.includes(b.name));

  // Only the closing text (after the last tool call) is the claim shown to the user.
  let lastTool = -1;
  blocks.forEach((b, i) => { if (b.type === 'tool_use') lastTool = i; });
  const fullText = blocks.slice(lastTool + 1)
    .filter(b => b.type === 'text')
    .map(b => b.text || '')
    .join(' ')
    .toLowerCase();
  const claimed = hasSuccessClaim(fullText);

  // Block only when: changes were made + success claimed + no verification run
  if (hasChanges && claimed && !hasVerification) {
    logFire('verify-before-stop', 'block', 'success-claim-no-verify', input.session_id);
    process.stderr.write(
      'VERIFICATION REQUIRED: You made changes (Write/Edit) and claimed success ' +
      '("done"/"fixed"/"works"/"готово"/"исправлено") without running any verification command.\n\n' +
      'Required: run a Bash command that actually checks the result (curl, test run, cat, grep). ' +
      'Paste the real output.\n' +
      'If you cannot verify with a terminal command — say so explicitly instead of claiming success.'
    );
    process.exit(2);
  }

  process.exit(0);
});

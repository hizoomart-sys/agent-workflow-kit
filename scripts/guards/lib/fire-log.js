// Tiny optional local logger: one JSONL line per barrier firing. No payloads, no prompts.
// Failure to log never breaks a barrier. Override the path with AWK_FIRE_LOG (tests).
const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = process.env.GUARD_RUNNER_HOME || path.join(os.homedir(), '.claude', 'workflow-kit');
const LOG = process.env.AWK_FIRE_LOG || path.join(HOME, 'telemetry', 'guard-fires.jsonl');
const MAX_BYTES = 2 * 1024 * 1024;

function logFire(guard, action, reason, session) {
  try {
    try { if (fs.statSync(LOG).size > MAX_BYTES) fs.renameSync(LOG, LOG + '.1'); } catch {}
    fs.mkdirSync(path.dirname(LOG), { recursive: true });
    fs.appendFileSync(LOG, JSON.stringify({
      ts: new Date().toISOString(), guard, action,
      reason: String(reason || '').slice(0, 60), session: session || null,
    }) + '\n');
  } catch {}
}

module.exports = { logFire, LOG };

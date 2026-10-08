// Tests for the destructive-git guard: bypass probes (shell executes -> must block),
// data controls (shell does not execute -> must pass), push forms, merge rule, runner wiring.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const GUARDS = resolve(HERE, '..', 'scripts', 'guards');
const H = process.env.HOOK_PATH || join(GUARDS, 'destructive-git-guard.sh');
const RUNNER = join(GUARDS, 'guard-runner.sh');

const TMP = mkdtempSync(join(tmpdir(), 'awk-dg-'));
process.env.AWK_FIRE_LOG = join(TMP, 'fires.jsonl');
process.env.GUARD_RUNNER_HOME = join(TMP, 'home');

const G = 'git ';
const HARD = '-' + '-hard';
const FORCE = '-' + '-for' + 'ce';
const RESET = G + 'reset ' + HARD + ' HEAD~1';
const P = G + 'push ';
const FL = FORCE;
const SH = '-' + 'f';

// [name, wantExit, command, cwd?]
const cases = [
  // --- bypass: the command really runs ---
  ['BLOCK subst-dollar',  2, 'echo $(' + RESET + ')'],
  ['BLOCK subst-tick',    2, 'echo `' + RESET + '`'],
  ['BLOCK after-and',     2, 'echo ok && ' + RESET],
  ['BLOCK after-semi',    2, 'echo ok; ' + RESET],
  ['BLOCK after-pipe',    2, 'echo ok | ' + RESET],
  ['BLOCK newline',       2, 'echo ok\n' + RESET],
  ['BLOCK env-prefix',    2, 'GIT_DIR=.git ' + RESET],
  ['BLOCK nice-prefix',   2, 'nice -n 10 ' + RESET],
  ['BLOCK abs-path',      2, '/usr/bin/' + RESET],
  ['BLOCK dash-C',        2, G + '-C /tmp/x reset ' + HARD + ' HEAD~1'],
  ['BLOCK in-if',         2, 'if true; then ' + RESET + '; fi'],
  ['BLOCK push-plus-sub', 2, 'echo $(' + G + 'push origin +main)'],
  ['BLOCK unbalanced',    2, "echo 'oops " + RESET],

  // --- data: the shell does not execute it ---
  ['PASS  heredoc',       0, "cat > t.sh <<'EOF'\n" + RESET + "\nEOF"],
  ['PASS  echo-single',   0, "echo '" + RESET + "'"],
  ['PASS  echo-double',   0, 'echo "' + RESET + '"'],
  ['PASS  grep-pattern',  0, 'grep -n "' + G + 'push" file.sh'],
  ['PASS  sed-arg',       0, "sed -i '' 's/x/" + G + 'branch -D y' + "/' f.txt"],
  ['PASS  node-e',        0, 'node -e "console.log(\'' + FORCE + '\')"'],

  // --- push forms ---
  ['BLOCK plus-refspec',  2, P + 'origin +claude/02174c62:claude/02174c62'],
  ['BLOCK plus-branch',   2, P + 'origin +main'],
  ['BLOCK flag-long',     2, P + FL + ' origin main'],
  ['BLOCK flag-short',    2, P + SH + ' origin main'],
  ['BLOCK combo-short',   2, P + '-u' + 'f origin main'],
  ['BLOCK flag-tail',     2, P + 'origin main ' + FL],
  ['PASS  with-lease',    0, P + FL + '-with-lease origin main'],
  ['PASS  lease-sha',     0, P + FL + '-with-lease=main:abc123 origin main'],
  ['PASS  plain',         0, P + 'origin main'],
  ['PASS  explicit-ref',  0, P + 'origin HEAD:refs/heads/main'],
  ['PASS  set-upstream',  0, P + '-u origin claude/abc'],
  ['PASS  tags',          0, P + '--tags origin'],
  ['PASS  bare',          0, 'git ' + 'push'],
  ['PASS  echo-plus',     0, 'echo a+b && ' + P + 'origin main'],

  // --- the rest ---
  ['BLOCK reset-hard',    2, G + 'reset ' + HARD + ' HEAD~1'],
  ['BLOCK clean',         2, G + 'clean ' + '-' + 'fd'],
  ['BLOCK branch-D',      2, G + 'branch ' + '-' + 'D claude/abc'],
  ['BLOCK merge-ff',      2, G + 'merge claude/abc'],
  ['PASS  merge-noff',    0, G + 'merge --no-ff claude/abc'],
  ['PASS  reset-soft',    0, G + 'reset --soft HEAD~1'],
  ['PASS  status',        0, G + 'status'],
];

// merge rule follows <repo>/.claude/workflow-kit.json "prefix"
const REPO = join(TMP, 'repo');
mkdirSync(join(REPO, '.claude'), { recursive: true });
writeFileSync(join(REPO, '.claude', 'workflow-kit.json'), JSON.stringify({ enabled: true, prefix: 'wip' }));
cases.push(
  ['BLOCK cfg-prefix-ff',     2, G + 'merge wip/abc', REPO],
  ['PASS  cfg-prefix-noff',   0, G + 'merge --no-ff wip/abc', REPO],
  ['PASS  cfg-other-prefix',  0, G + 'merge claude/abc', REPO],
);

// quoted / escaped executable, subcommand, flag: the shell still runs git reset --hard
cases.push(
  ['BLOCK quoted-git-sq',   2, "'git' reset " + HARD + ' HEAD~1'],
  ['BLOCK quoted-git-dq',   2, '"git" reset ' + HARD + ' HEAD~1'],
  ['BLOCK escaped-git',     2, 'g\\it reset ' + HARD + ' HEAD~1'],
  ['BLOCK quoted-sub',      2, "git 'reset' " + HARD + ' HEAD~1'],
  ['BLOCK quoted-flag',     2, 'git reset "' + HARD + '" HEAD~1'],
  ['BLOCK quoted-env-pfx',  2, 'FOO="a b" ' + RESET],
  ['BLOCK quoted-dash-C',   2, G + '-C "/tmp/a b" reset ' + HARD],
  ['PASS  echo-quoted-git', 0, "echo 'git' reset " + HARD],
  ['PASS  commit-msg',      0, G + 'commit -m "reset ' + HARD + '"'],
  // lease must not mask a plain force
  ['BLOCK force-then-lease', 2, P + FL + ' ' + FL + '-with-lease origin main'],
  ['BLOCK lease-then-force', 2, P + FL + '-with-lease ' + FL + ' origin main'],
  ['BLOCK lease-plus-ref',   2, P + FL + '-with-lease origin +main'],
  // --squash does not need --no-ff; --ff-only still blocks
  ['PASS  merge-squash',     0, G + 'merge --squash claude/task'],
  ['BLOCK merge-ff-only',    2, G + 'merge --ff-only claude/task'],
);

let bad = 0;
function run(file, args, payload, env) {
  try {
    execFileSync(file, args, { input: payload, stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...env } });
    return 0;
  } catch (e) { return e.status; }
}
function report(name, want, code, cmd) {
  const ok = code === want;
  if (!ok) bad++;
  console.log((ok ? 'ok  ' : 'FAIL') + '  exit=' + code + ' want=' + want + '  ' + name.padEnd(22) + JSON.stringify(cmd).slice(0, 60));
}

for (const [name, want, cmd, cwd] of cases) {
  const payload = JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', cwd: cwd || TMP, tool_input: { command: cmd } });
  report(name, want, run('bash', [H], payload, {}), cmd);
}

// through guard-runner: a crashing hook must fail closed (exit 2), a healthy block stays 2
const BROKEN = join(TMP, 'broken.sh');
writeFileSync(BROKEN, '#!/usr/bin/env bash\nexit 1\n');
report('RUNNER crash->block', 2, run('bash', [RUNNER, '--name', 'dg-test', '--fail-mode', 'block', '--', BROKEN], '{}', {}), 'broken hook');
report('RUNNER warn->pass',   0, run('bash', [RUNNER, '--name', 'dg-test', '--fail-mode', 'warn', '--', BROKEN], '{}', {}), 'broken hook');
const blockPayload = JSON.stringify({ tool_name: 'Bash', cwd: TMP, tool_input: { command: RESET } });
report('RUNNER real block',   2, run('bash', [RUNNER, '--name', 'destructive-git', '--fail-mode', 'block', '--', H], blockPayload, {}), RESET);

rmSync(TMP, { recursive: true, force: true });
console.log(bad === 0 ? 'ALL OK' : bad + ' FAILED');
process.exit(bad === 0 ? 0 : 1);

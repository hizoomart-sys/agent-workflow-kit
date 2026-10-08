// Verdict on destructive git commands: judged by the ACTION, not by how it is spelled.
//
// Two failure modes of string-regex guards that this avoids:
//  1) `push origin +branch:branch` rewrites history exactly like a force flag, but the
//     flag text is absent -> a regex guard is bypassed by changing the FORM of the command;
//  2) a guarded string inside DATA (heredoc body, echo argument, sed pattern) destroys
//     nothing, yet a regex guard blocks it like a real launch.
//
// shell-parse.js strips heredocs, removes quotes and marks unquoted characters.
// Unclosed quote -> parse is unreliable -> fail closed to a naive scan.

const fs = require("fs");
const path = require("path");
const { parseCommand, naiveSegments } = require("./shell-parse");
const { logFire } = require("./fire-log");

// A token counts by the word the shell will see (quotes and escapes removed): 'git' and
// g\it both launch git. Quoted DATA (echo 'git reset --hard') is one multi-word token
// and never equals a command or subcommand name.
const isBare = tok => tok && tok.text.length > 0;

// Prefixes that may precede the real command: env VAR=1 git ..., sudo git ...
const PREFIXES = ["env", "nice", "sudo", "command", "nohup", "time", "xargs", "then", "else", "do"];
// Prefix flags that swallow their own argument: `nice -n 10 git ...`.
const PREFIX_FLAGS_WITH_ARG = new Set(["-n", "-u", "-g", "-C", "--adjustment"]);

function gitArgs(tokens) {
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (!isBare(t)) return null;
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t.text)) { i++; continue; }
    if (PREFIXES.includes(t.text)) { i++; continue; }
    if (PREFIX_FLAGS_WITH_ARG.has(t.text)) { i += 2; continue; }
    if (/^-/.test(t.text)) { i++; continue; }
    break;
  }
  const head = tokens[i];
  if (!head || !isBare(head)) return null;
  if (head.text !== "git" && !/(^|\/)git$/.test(head.text)) return null;

  const rest = tokens.slice(i + 1).filter(isBare);
  // global git options before the subcommand: -C <path>, -c <k=v>, --git-dir=...
  let j = 0;
  while (j < rest.length && rest[j].text.startsWith("-")) {
    if (rest[j].text === "-C" || rest[j].text === "-c") j += 2; else j += 1;
  }
  if (j >= rest.length) return null;
  return { sub: rest[j].text, args: rest.slice(j + 1).map(t => t.text) };
}

function destructiveVerdict(tokens) {
  const g = gitArgs(tokens);
  if (!g) return null;
  const { sub, args } = g;

  if (sub === "push") {
    let force = false;
    for (const a of args) {
      // lease / if-includes refuse when the remote moved ahead: the safe form, allowed
      // only when no plain --force / -f / +refspec appears alongside it.
      if (a === "--force-with-lease" || a.startsWith("--force-with-lease=") || a === "--force-if-includes") continue;
      if (a === "--force" || a === "-f") { force = true; continue; }
      if (/^-[A-Za-z]+$/.test(a) && a.includes("f")) { force = true; continue; } // bundled -uf
      if (a.startsWith("+") && a.length > 1) { force = true; continue; }          // +refspec
    }
    return force
      ? "git push --force (rewrites history on the remote; flag or +refspec form)"
      : null;
  }

  if (sub === "reset" && args.includes("--hard")) return "git reset --hard";

  if (sub === "clean" && args.some(a => a === "--force" || /^-[A-Za-z]*f/.test(a))) {
    return "git clean -f";
  }

  if (sub === "branch" && args.some(a => a === "-D" || (/^-[A-Za-z]+$/.test(a) && a.includes("D")))) {
    return "git branch -D";
  }

  return null;
}

// Session-branch prefix from <repo>/.claude/workflow-kit.json (key "prefix"), default "claude".
// The repo is found by walking up from the payload cwd.
function sessionPrefix(cwd) {
  let dir = cwd || process.cwd();
  for (let i = 0; i < 40; i++) {
    try {
      const cfg = JSON.parse(fs.readFileSync(path.join(dir, ".claude", "workflow-kit.json"), "utf8"));
      if (cfg && typeof cfg.prefix === "string" && cfg.prefix) return cfg.prefix;
      return "claude";
    } catch {}
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return "claude";
}

// merge <prefix>/* without --no-ff: a fast-forward makes the merge invisible in `git log --merges`.
function isMergeFf(tokens, prefix) {
  const g = gitArgs(tokens);
  if (!g || g.sub !== "merge") return false;
  if (!g.args.some(a => a.includes(prefix + "/"))) return false;
  return !g.args.includes("--no-ff") && !g.args.includes("--squash");
}

// Unclosed quote -> cannot tell data from a launch. Fail closed: try to read the command
// from EVERY position of the segment, not only from its start.
function unsafeVerdict(cmd) {
  for (const tokens of naiveSegments(cmd)) {
    for (let k = 0; k < tokens.length; k++) {
      const reason = destructiveVerdict(tokens.slice(k));
      if (reason) return reason;
    }
  }
  return null;
}

function analyze(cmd, prefix = "claude") {
  const parsed = parseCommand(cmd);
  if (parsed.unbalanced) {
    const reason = unsafeVerdict(cmd);
    if (reason) return { kind: "destructive", reason };
  }
  const segments = parsed.unbalanced ? naiveSegments(cmd) : parsed.segments;
  for (const tokens of segments) {
    const reason = destructiveVerdict(tokens);
    if (reason) return { kind: "destructive", reason };
  }
  for (const tokens of segments) {
    if (isMergeFf(tokens, prefix)) return { kind: "merge-ff", prefix };
  }
  return null;
}

module.exports = { analyze };

if (require.main === module) {
  let d = "";
  process.stdin.on("data", c => (d += c));
  process.stdin.on("end", () => {
    let cmd = "";
    let cwd = "";
    let session = null;
    try {
      const p = JSON.parse(d);
      cmd = (p.tool_input && p.tool_input.command) || "";
      cwd = p.cwd || "";
      session = p.session_id || null;
    } catch { cmd = ""; }
    if (!cmd) process.exit(0);

    let v = null;
    try { v = analyze(cmd, sessionPrefix(cwd)); } catch { v = null; }
    if (!v) process.exit(0);

    logFire("destructive-git-guard", "block", v.kind, session);
    const reason = v.kind === "merge-ff"
      ? `BLOCKED: git merge ${v.prefix}/* without --no-ff. A fast-forward makes the merge invisible in \`git log --merges\`. Add --no-ff or use \`wt merge\`. Or run the command yourself in your own terminal.`
      : `BLOCKED: destructive git command (${v.reason}). Ask the user to confirm; the user can run the command themselves if they really want it.`;
    process.stderr.write(reason + "\n");
    process.exit(2);
  });
}

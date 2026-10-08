#!/usr/bin/env python3
"""
save-session.py: one-shot session save. CONTEXT append + archive rotation +
RESUME regen + optional git commit.

Usage:
    save-session.py "<title>" < block_body
    save-session.py "<title>" --body "<inline body>"

Block body: bullets only, fields by name (RU or EN alias):
    - Сделано / Done
    - Не сделано / Not done
    - Следующий шаг / Next
    - Что не сработало / Avoid      (optional)
    - Инфра / Infra                 (optional)
    - Ждёт пользователя / Waiting on user  (optional)
    - Решения-инсайты / Insights    (optional)
    - Файлы / Files                 (optional, list under the field)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

FALLBACK_PLANNING = Path(
    os.environ.get("AWK_FALLBACK_DIR") or Path.home() / ".claude/workflow-kit/sessions/.planning"
)

ACTIVE_BLOCKS_LIMIT = 5   # blocks above the --- divider
MAX_BLOCK_LINES = 25      # slim format: hard cap on body lines per block


# ---------- helpers --------------------------------------------------------

def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=check)


def find_planning_dir() -> tuple[Path, str]:
    """
    Walk up from cwd looking for existing .planning/. First match wins.
    If none found and cwd is inside a git repo -> create at git root.
    Otherwise -> FALLBACK_PLANNING (env AWK_FALLBACK_DIR or ~/.claude/workflow-kit/sessions/.planning).
    Returns (planning_dir, mode) where mode in {"existing", "created", "fallback"}.
    """
    cwd = Path.cwd().resolve()
    for parent in [cwd, *cwd.parents]:
        candidate = parent / ".planning"
        if candidate.is_dir():
            return candidate, "existing"
    try:
        result = run(["git", "rev-parse", "--show-toplevel"], check=False)
        if result.returncode == 0:
            root = Path(result.stdout.strip())
            planning = root / ".planning"
            planning.mkdir(parents=True, exist_ok=True)
            return planning, "created"
    except FileNotFoundError:
        pass
    FALLBACK_PLANNING.mkdir(parents=True, exist_ok=True)
    return FALLBACK_PLANNING, "fallback"


def kit_conf(repo: str | Path) -> tuple[str, str]:
    """(branch prefix, base branch) from <repo>/.claude/workflow-kit.json."""
    try:
        d = json.loads((Path(repo) / ".claude/workflow-kit.json").read_text())
    except Exception:
        d = {}
    return d.get("prefix") or "claude", d.get("base") or "main"


def resolver_planning(cwd: Path) -> str | None:
    """Canonical planning dir via the sibling session-resolve.sh (READ/WRITE symmetry).
    Worktree -> <main>/.planning/sessions/<sid>; main checkout -> <main>/.planning.
    None on failure."""
    resolver = Path(__file__).resolve().parent / "session-resolve.sh"
    if not resolver.exists():
        return None
    res = run(["bash", str(resolver), "planning", "--cwd", str(cwd)], check=False)
    out = res.stdout.strip()
    if res.returncode == 0 and out and out != "SESSION_RESUME_AMBIGUOUS":
        return out
    return None


def parse_blocks(text: str) -> list[str]:
    """Split markdown into blocks starting with '## '. Any leading text before
    the first '## ' is dropped (it's preserved separately as preamble)."""
    blocks: list[str] = []
    current: list[str] | None = None
    for line in text.splitlines():
        if line.startswith("## "):
            if current is not None:
                blocks.append("\n".join(current).rstrip())
            current = [line]
        elif current is not None:
            current.append(line)
    if current is not None:
        blocks.append("\n".join(current).rstrip())
    return blocks


def extract_preamble(text: str) -> str:
    """Return everything before the first '## ' heading (keeps project H1, intro)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("## "):
            return "\n".join(lines[:i]).rstrip()
    return text.rstrip()


def split_active_archived(text: str) -> tuple[str, list[str], list[str]]:
    """Split CONTEXT.md content into (preamble, active_blocks, archived_blocks)."""
    if not text.strip():
        return "", [], []
    preamble = extract_preamble(text)
    parts = re.split(r"(?m)^---\s*$", text, maxsplit=1)
    pre = parts[0]
    post = parts[1] if len(parts) > 1 else ""
    return preamble, parse_blocks(pre), parse_blocks(post)


def join_blocks(blocks: list[str]) -> str:
    return "\n\n".join(blocks).strip() + "\n" if blocks else ""


def block_year_month(block: str) -> str | None:
    """Extract YYYY-MM from '## YYYY-MM-DD — ...' header."""
    m = re.match(r"^##\s+(\d{4}-\d{2})-\d{2}\b", block)
    return m.group(1) if m else None


def field(block: str, name: str) -> str | None:
    """Extract a field value, tolerant of how it was written.

    Accepts the field as a bullet (`- Name: value`), a bare line (`Name: value`),
    or a markdown heading (`## Name` with value on following lines). Empty markers
    `-` and `—` (em-dash) both count as no value.
    """
    pattern = (
        rf"^(?:#+\s*|-\s*)?{re.escape(name)}:?[ \t]*(.*?)"
        rf"(?=\n-\s|\n#|\Z)"
    )
    m = re.search(pattern, block, re.DOTALL | re.MULTILINE)
    if not m:
        return None
    value = m.group(1).strip()
    return value if value and value not in ("-", "—") else None


def list_field(block: str, name: str) -> list[str] | None:
    """Поле-список: строки-пункты под `Name:` до следующего известного поля.

    `field()` обрывает значение на первой строке `- …`, а пункты списка пишутся
    именно так — поэтому для списков нужен отдельный разбор.
    """
    out: list[str] = []
    grab = False
    head = re.compile(rf"^(?:#+\s*|-\s*)?{re.escape(name)}:?\s*(.*)$", re.IGNORECASE)
    for ln in block.splitlines():
        s = ln.strip()
        if not grab:
            m = head.match(s)
            if m:
                grab = True
                first = m.group(1).strip().lstrip("-•*").strip()
                if first:
                    out.append(first)
            continue
        if _FIELD_LINE.match(s):
            break
        item = s.lstrip("-•*").strip()
        if item:
            out.append(item)
    return out or None


def title_from_block(block: str) -> str:
    m = re.match(r"^##\s+\d{4}-\d{2}-\d{2}\s+—\s+(.+?)\s*$", block, re.MULTILINE)
    return m.group(1).strip() if m else "session"


def session_id() -> str | None:
    """Return CLAUDE_CODE_SESSION_ID from env, or None."""
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or None


def in_worktree(path: Path) -> bool:
    """True if `path` is inside a git linked worktree (not the main checkout).

    Explicit `git -C` instead of inherited process cwd; git prints these paths
    relative to its cwd, so resolve both against `path` before comparing.
    """
    common = run(["git", "-C", str(path), "rev-parse", "--git-common-dir"], check=False)
    gitdir = run(["git", "-C", str(path), "rev-parse", "--git-dir"], check=False)
    if common.returncode != 0 or gitdir.returncode != 0:
        return False
    base = path.resolve()
    c = (base / common.stdout.strip()).resolve()
    g = (base / gitdir.stdout.strip()).resolve()
    return c != g


def in_git_repo(path: Path) -> bool:
    res = run(["git", "-C", str(path), "rev-parse", "--git-dir"], check=False)
    return res.returncode == 0


def last_commit_oneline(path: Path) -> str | None:
    res = run(["git", "-C", str(path), "log", "-1", "--pretty=format:%h %s"], check=False)
    return res.stdout.strip() if res.returncode == 0 and res.stdout.strip() else None


def compute_status(next_raw: str | None, blockers_raw: str | None,
                   human_pending_raw: str | None, infra_raw: str | None = None) -> str:
    if human_pending_raw:
        return "waiting_user"
    # Непустая «Инфра» — durable-сигнал незавершённого состояния (нужен deploy/reload/
    # ручное действие над инфрой) → не complete (план параллельных сессий, сквозное).
    if next_raw or blockers_raw or infra_raw:
        return "in_progress"
    return "complete"


def compute_integration_status(planning: Path, cwd: Path | None = None) -> tuple[str, str | None]:
    """Влита ли ветка сессии в base — ОТДЕЛЬНО от статуса разговора.

    Возвращает (статус, имя_ветки). Имя нужно новой сессии, чтобы вернуться в ветку
    незакрытой работы. Ветку берём из cwd сессии, не из `planning`: session-dir лежит
    внутри main-checkout, и git по этому пути всегда отвечает «base».

    merged  — ветки нет (удалена после merge) либо она не опережает base
    pending — ветка есть и содержит невлитые коммиты
    unknown — не git / не сессионная ветка / git недоступен (fail-open)
    """
    probe = cwd if cwd is not None else planning
    try:
        repo = subprocess.run(
            ["git", "-C", str(probe), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if repo.returncode != 0:
            return "unknown", None
        root = repo.stdout.strip()
        prefix, base = kit_conf(root)

        branch = subprocess.run(
            ["git", "-C", root, "branch", "--show-current"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if not branch.startswith(prefix + "/"):
            return "unknown", None

        ahead = subprocess.run(
            ["git", "-C", root, "rev-list", "--count", f"{base}..{branch}"],
            capture_output=True, text=True, timeout=5,
        )
        if ahead.returncode != 0:
            return "unknown", branch
        if ahead.stdout.strip() not in ("", "0"):
            return "pending", branch
        return "merged", branch
    except Exception:
        return "unknown", None


# ---------- core steps -----------------------------------------------------

# Canonical body fields that RESUME/status logic reads — must survive slimming
# regardless of how they were written (bullet, bare line, or `## Heading`).
KNOWN_FIELDS = (
    "Сделано", "Не сделано", "Следующий шаг", "Что не сработало",
    "Инфра", "Ждёт пользователя", "Решения-инсайты", "Файлы",
)
# English aliases → canonical Russian field. Без алиасов поданные `next:`/`human_pending:`
# молча выбрасывались бы, и status уехал бы в complete вместо waiting_user.
EN_ALIASES = {
    "done": "Сделано",
    "blockers": "Не сделано",
    "todo": "Не сделано",
    "next": "Следующий шаг",
    "next step": "Следующий шаг",
    "not done": "Не сделано",
    "waiting on user": "Ждёт пользователя",
    "avoid": "Что не сработало",
    "infra": "Инфра",
    "human_pending": "Ждёт пользователя",
    "waiting_user": "Ждёт пользователя",
    "insights": "Решения-инсайты",
    "decisions": "Решения-инсайты",
    "files": "Файлы",
    "документы": "Файлы",
}
_FIELD_LINE = re.compile(
    rf"^(?:#+\s*|-\s*)?"
    rf"({'|'.join(re.escape(f) for f in sorted((*KNOWN_FIELDS, *EN_ALIASES), key=len, reverse=True))}):?\s*(.*)$",
    re.IGNORECASE,
)
# Field-shaped line (`Имя: значение`, опц. `## `-заголовок) — для warning'а
# о нераспознанных полях, которые slim_body молча выбрасывает.
_FIELDISH = re.compile(r"^(?:#+\s*)?([^:\n]{1,40}):(?:\s|$)")


def normalize_field_line(line: str) -> str | None:
    """If `line` is a known field written as heading / bare / bullet, return it
    canonicalized to `- Name: value` (value may be empty). Else None."""
    m = _FIELD_LINE.match(line.strip())
    if not m:
        return None
    name, value = m.group(1), m.group(2).strip()
    # EN-алиас (или его регистровый вариант) → канонический русский заголовок
    canonical = EN_ALIASES.get(name.lower())
    if canonical is not None:
        name = canonical
    return f"- {name}: {value}".rstrip()


def slim_body(body: str) -> tuple[str, bool]:
    """
    Enforce slim format: drop any line that isn't a top-level bullet (`- `)
    or a continuation under one. Cap total at MAX_BLOCK_LINES. Return
    (trimmed_body, was_truncated).

    Heuristic: keep lines starting with '- ' (top-level bullet) plus their
    inline continuations (lines starting with 2+ spaces). Known canonical
    fields are kept and normalized to `- Name: value` even if written as a
    `## Heading` or a bare `Name:` line. Drop fenced code, raw dumps,
    full diffs, blank lines beyond one between bullets.
    """
    lines = body.splitlines()
    kept: list[str] = []
    unrecognized: list[str] = []
    in_fence = False
    pending_field: str | None = None  # canonical field awaiting heading-style value
    for raw in lines:
        line = raw.rstrip()
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not line.strip():
            if kept and kept[-1] != "":
                kept.append("")
            continue
        canonical = normalize_field_line(line)
        if canonical is not None:
            kept.append(canonical)
            # `## Ждёт пользователя` with value on the next line → capture it
            pending_field = canonical if canonical.endswith(":") else None
            continue
        if pending_field is not None:
            # value line directly under a heading-style field
            kept[-1] = f"{pending_field} {line.strip()}".rstrip()
            pending_field = None
            continue
        if line.startswith("- ") or line.startswith("  "):
            kept.append(line)
            continue
        # plain prose / heading / dump → drop
        fm = _FIELDISH.match(line.strip())
        if fm and fm.group(1).strip() not in KNOWN_FIELDS:
            unrecognized.append(fm.group(1).strip())
    while kept and kept[-1] == "":
        kept.pop()
    if unrecognized:
        print(
            "⚠ нераспознанные поля выброшены slim-фильтром: "
            + ", ".join(dict.fromkeys(unrecognized))
            + f" — известные: {', '.join(KNOWN_FIELDS)}",
            file=sys.stderr,
        )

    truncated = False
    if len(kept) > MAX_BLOCK_LINES:
        kept = kept[:MAX_BLOCK_LINES]
        kept.append(f"  …(truncated to {MAX_BLOCK_LINES} lines — see commit/files for detail)")
        truncated = True
    return "\n".join(kept), truncated


def build_block(title: str, body: str, date: str) -> str:
    body, truncated = slim_body(body)
    if truncated:
        print(f"⚠ block body exceeded {MAX_BLOCK_LINES} lines — truncated", file=sys.stderr)
    body = body.rstrip()
    return f"## {date} — {title}\n{body}\n"


def flush_archived_to_files(planning: Path, archived: list[str]) -> list[tuple[str, int]]:
    """
    Move every block currently sitting below the `---` divider out of CONTEXT.md
    into CONTEXT-archive-YYYY-MM.md files. Mutates `archived` to []. This is the
    canonical place for old context — keeping CONTEXT.md small.
    """
    if not archived:
        return []
    by_month: dict[str, list[str]] = {}
    for blk in archived:
        ym = block_year_month(blk) or "undated"
        by_month.setdefault(ym, []).append(blk)
    summary: list[tuple[str, int]] = []
    for ym, blocks in by_month.items():
        archive_path = planning / f"CONTEXT-archive-{ym}.md"
        existing = archive_path.read_text() if archive_path.exists() else ""
        new_content = join_blocks(blocks)
        if existing.strip():
            archive_path.write_text(existing.rstrip() + "\n\n" + new_content)
        else:
            archive_path.write_text(new_content)
        summary.append((archive_path.name, len(blocks)))
    archived.clear()
    return summary


def rotate_archive(planning: Path, active: list[str]) -> list[tuple[str, int]]:
    """
    If active > LIMIT, move oldest blocks to CONTEXT-archive-YYYY-MM.md
    (grouped by month from each block's date). Returns list of (filename, count).
    Mutates `active` to keep only the LIMIT newest.
    """
    if len(active) <= ACTIVE_BLOCKS_LIMIT:
        return []

    to_archive = active[ACTIVE_BLOCKS_LIMIT:]
    del active[ACTIVE_BLOCKS_LIMIT:]

    by_month: dict[str, list[str]] = {}
    for blk in to_archive:
        ym = block_year_month(blk) or "undated"
        by_month.setdefault(ym, []).append(blk)

    summary: list[tuple[str, int]] = []
    for ym, blocks in by_month.items():
        archive_path = planning / f"CONTEXT-archive-{ym}.md"
        existing = archive_path.read_text() if archive_path.exists() else ""
        new_content = join_blocks(blocks)
        if existing.strip():
            archive_path.write_text(existing.rstrip() + "\n\n" + new_content)
        else:
            archive_path.write_text(new_content)
        summary.append((archive_path.name, len(blocks)))
    return summary


def write_context(planning: Path, preamble: str, active: list[str], archived: list[str]) -> Path:
    context_path = planning / "CONTEXT.md"
    parts: list[str] = []
    if preamble.strip():
        parts.append(preamble.rstrip())
    parts.append(join_blocks(active).rstrip())
    if archived:
        parts.append("---")
        parts.append(join_blocks(archived).rstrip())
    # .bak перед перезаписью, симметрично write_resume() — восстановимость при ошибочном прогоне.
    if context_path.exists():
        context_path.with_name("CONTEXT.md.bak").write_text(
            context_path.read_text(errors="ignore")
        )
    # atomic: незавершённая запись не должна оставить CONTEXT.md пустым/обрезанным
    tmp_path = context_path.with_name(context_path.name + ".tmp")
    tmp_path.write_text("\n\n".join(parts) + "\n")
    tmp_path.replace(context_path)
    return context_path


def build_resume(top_block: str, planning: Path, sid: str | None = None) -> str:
    title = title_from_block(top_block)
    next_raw = field(top_block, "Следующий шаг")
    blockers_raw = field(top_block, "Не сделано")
    avoid = field(top_block, "Что не сработало")
    infra = field(top_block, "Инфра")
    human_pending = field(top_block, "Ждёт пользователя")

    status = compute_status(next_raw, blockers_raw, human_pending, infra)
    next_step = next_raw or "-"
    blockers = blockers_raw or "-"

    last_commit = last_commit_oneline(planning) or "-"
    saved_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Влитость ветки — отдельная ось от статуса разговора:
    # status отвечает «ждём человека?», integration_status — «код в base?».
    integration_status, session_branch = compute_integration_status(planning, Path.cwd())

    lines = [
        "<!-- auto-generated on save, do not edit -->",
        f"where: {title}",
        f"status: {status}",
        f"integration_status: {integration_status}",
    ]
    # Ветка пишется ТОЛЬКО при pending: у влитой возвращаться некуда, поле было бы шумом.
    if integration_status == "pending" and session_branch:
        lines.append(f"session_branch: {session_branch}")
    # Идентичность сессии в RESUME — основа для clobber-guard и резолвера.
    if sid:
        lines.append(f"session_id: {sid}")
    lines += [
        f"next: {next_step}",
        f"blockers: {blockers}",
    ]
    if avoid:
        lines.append(f"avoid: {avoid}")
    if infra:
        lines.append(f"infra: {infra}")
    if human_pending:
        lines.append(f"human_pending: {human_pending}")
    lines.append(f"last_commit: {last_commit}")
    lines.append(f"saved_at: {saved_at}")
    return "\n".join(lines) + "\n"


def write_resume(planning: Path, content: str) -> Path:
    resume_path = planning / "RESUME.md"
    # .bak перед перезаписью: клоббер чужой карточки обязан быть обратим.
    # Имя копии несёт SID вытесняемого владельца: RESUME.md.<sid>.bak — одна копия на владельца.
    if resume_path.exists():
        prev = resume_path.read_text(errors="ignore")
        prev_sid = ""
        m = re.search(r"^session_id:\s*(\S+)", prev, re.M)
        if m:
            prev_sid = re.sub(r"[^0-9a-zA-Z_-]", "", m.group(1))[:16]
        suffix = f".{prev_sid}.bak" if prev_sid else ".bak"
        resume_path.with_name(resume_path.name + suffix).write_text(prev)
    # atomic: temp→rename — читатель (резолвер/precompact) никогда не видит
    # обрезанный RESUME. rename атомарен в пределах одной ФС.
    tmp_path = resume_path.with_name(resume_path.name + ".tmp")
    tmp_path.write_text(content)
    tmp_path.replace(resume_path)
    return resume_path


def _parse_resume_fields(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="ignore").splitlines():
        m = re.match(r"^(session_id|status|where|saved_at):\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


# Владелец карточки считается живым, если его транскрипт трогали не позже этого срока (72 ч).
# Отказа нет: при «живом» владельце скрипт пишет свою карточку в sessions/<sid>/.
SESSION_ALIVE_MIN = 4320


def session_last_active_min(sid: str) -> float | None:
    """Минут с последней активности сессии `sid`, или None если транскрипта нет.

    Транскрипт `~/.claude/projects/<slug>/<sid>.jsonl` дописывается на каждом ходе —
    это рабочий сигнал живости: lsof по транскрипту пуст (файл пишется и закрывается),
    а pid→sid не связать.
    """
    if not sid:
        return None
    hits = sorted(Path.home().glob(f".claude/projects/*/{sid}.jsonl"))
    if not hits:
        return None
    newest = max(h.stat().st_mtime for h in hits)
    return (time.time() - newest) / 60


def guard_root_resume_owner(planning: Path, sid: str | None, title: str) -> Path:
    """Куда писать, чтобы не затереть карточку параллельной сессии.

    Возвращает planning для записи: корневой — если он свободен или его владелец мёртв;
    иначе `planning/sessions/<sid>` (своя карточка рядом, чужая цела).

    Живость владельца — по mtime транскрипта; отказа нет, деградируем в sessions/<sid>/.
    """
    if os.environ.get("SAVE_SESSION_ALLOW_ROOT"):
        return planning
    f = _parse_resume_fields(planning / "RESUME.md")
    if not f:
        return planning
    if f.get("status", "") not in ("in_progress", "waiting_user"):
        return planning  # complete/пустой → свободно перезаписывать
    other_sid = f.get("session_id", "")
    if (sid and other_sid == sid) or f.get("where", "") == title:
        return planning  # моя же сессия (по sid или по where) — не клоббер
    where = f.get("where", "?")
    sid_part = f" (session {other_sid[:8]})" if other_sid else ""

    idle = session_last_active_min(other_sid)
    if idle is not None and idle > SESSION_ALIVE_MIN:
        print(
            f"ℹ️  корневой RESUME числится за сессией{sid_part} «{where}» [{f.get('status')}], "
            f"но она молчит {int(idle)} мин (> {SESSION_ALIVE_MIN}) → считаю мёртвой, перезаписываю. "
            f"Бэкап: {planning / 'RESUME.md.bak'}",
            file=sys.stderr,
        )
        return planning

    # Владелец жив (или живость не определить). Не отказываем: своя карточка уходит в
    # sessions/<sid>/, CONTEXT.md всё равно общий и получит блок.
    if not sid:
        print(
            f"⛔ корневой {planning / 'RESUME.md'} принадлежит живой сессии{sid_part}: «{where}», "
            f"а свой session_id неизвестен (CLAUDE_CODE_SESSION_ID пуст) → некуда деградировать.\n"
            f"   → передай свою сессию явно: --sid <id>",
            file=sys.stderr,
        )
        sys.exit(3)
    idle_part = f"активна {int(idle)} мин назад" if idle is not None else "живость не определить"
    print(
        f"ℹ️  корневой RESUME занят живой сессией{sid_part} «{where}» ({idle_part}) → "
        f"пишу свою карточку в sessions/{sid[:8]}/, чужую не трогаю.",
        file=sys.stderr,
    )
    return planning / "sessions" / sid


def flatten_field(value: str | None, limit: int = 260) -> str | None:
    """Многострочное поле (буллеты/переносы) → одна строка для фенса.

    Фенс копируется в пустое окно целиком, поэтому он должен быть плотным:
    буллеты склеиваем через «; », хвост за limit обрезаем многоточием.
    """
    if not value:
        return None
    parts = [ln.strip().lstrip("-•*").strip() for ln in value.splitlines()]
    flat = "; ".join(p for p in parts if p)
    if len(flat) > limit:
        flat = flat[:limit].rstrip(" ;,") + "…"
    return flat or None


def print_session_card(title: str, status: str, next_step: str, blockers: str,
                       avoid: str | None, infra: str | None, human_pending: str | None,
                       done: str | None = None, files: list[str] | None = None,
                       resume_path: str | None = None, branch: str | None = None,
                       worktree: str | None = None) -> None:
    sep = "-" * 48
    print()
    print(sep)
    print(f"Сессия: {title}")
    if status == "complete":
        print("Статус: complete -- нет открытых задач")
    elif status == "waiting_user":
        print("Статус: waiting_user")
        if human_pending:
            print(f"! ждёт:   {human_pending}")
        if next_step != "-":
            print(f"-> затем: {next_step}")
    else:
        print("Статус: in_progress")
        if next_step != "-":
            print(f"-> next:  {next_step}")
        if blockers != "-":
            print(f"!= todo:  {blockers}")
        if avoid:
            print(f"X  avoid: {avoid}")
        if infra:
            print(f"~  infra: {infra}")
    print(sep)
    if status != "complete":
        # Фенс = САМОДОСТАТОЧНЫЙ вход в новую сессию: её контекст пуст, и всё, что она получит —
        # это то, что оператор скопирует отсюда. Поэтому кладём не только тему, а: с чего начать
        # (next), что было сделано (done), какие файлы трогали (files) и где лежат детали (RESUME).
        # Первое слово — «продолжаем»: это триггер §Resume, он должен остаться первым.
        # Тема в первой строке = title (о чём сессия), а конкретный шаг — отдельной строкой
        # «Начать с». Раньше в первой строке стоял next, и при расширенном фенсе он дублировался
        # с «Начать с» слово в слово — дубль убран, тема и шаг теперь несут разное.
        resume_topic = title.split("(")[0].strip().rstrip("—-,").strip()
        print()
        print("Продолжить в новой сессии:")
        print()
        print(f"```")
        print(f"продолжаем {resume_topic}")
        print()
        # Ветка и worktree: новая сессия иначе режет worktree от main и не видит невлитую работу.
        if branch:
            print(f"Ветка: {branch}" + (f" (worktree: {worktree})" if worktree else ""))
        if done:
            print(f"Сделано: {done}")
        if files:
            print("Документы:")
            for f in files:
                print(f"- {f}")
        if next_step != "-":
            print(f"Начать с: {next_step}")
        if human_pending:
            print(f"Ждёт: {human_pending}")
        if resume_path:
            print(f"Детали: {resume_path}")
        print(f"```")
    else:
        print()
        print("сессия закрыта, открытых задач нет.")
    # Финал-маркер: всё, что выводит save-session, заканчивается здесь.
    # Claude НЕ должен печатать ничего после этой строки, кроме фенса «продолжаем».
    print("⟦save-session: конец вывода — ничего больше не печатать⟧")


def git_commit(planning: Path, paths: list[Path], title: str) -> tuple[bool, str]:
    if not in_git_repo(planning):
        return False, "no git — skipped commit"
    repo_root = Path(run(["git", "-C", str(planning), "rev-parse", "--show-toplevel"]).stdout.strip())

    rel_paths = []
    for p in paths:
        try:
            rel_paths.append(str(p.resolve().relative_to(repo_root.resolve())))
        except ValueError:
            continue
    if not rel_paths:
        return False, "no files inside git repo"

    add = run(["git", "-C", str(repo_root), "add", *rel_paths], check=False)
    if add.returncode != 0:
        return False, f"git add failed: {add.stderr.strip()}"

    diff = run(["git", "-C", str(repo_root), "diff", "--cached", "--quiet"], check=False)
    if diff.returncode == 0:
        return False, "no changes to commit"

    commit = run(["git", "-C", str(repo_root), "commit", "-m", f"context: {title}"], check=False)
    if commit.returncode != 0:
        return False, f"git commit failed: {commit.stderr.strip() or commit.stdout.strip()}"
    sha_res = run(["git", "-C", str(repo_root), "log", "-1", "--pretty=format:%h"], check=False)
    sha = sha_res.stdout.strip() if sha_res.returncode == 0 else "?"
    return True, f"commit {sha}"


# ---------- main -----------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Session save: CONTEXT/RESUME/commit in one shot.")
    parser.add_argument("title", help="Short session title (Russian or English).")
    parser.add_argument("--body", help="Block body. If omitted, read from stdin.")
    parser.add_argument("--commit", action="store_true", help="Commit context files after save.")
    parser.add_argument("--sid", help="Адресовать свою сессию явно: писать в sessions/<sid>/ даже "
                        "если свой worktree исчез (P3). По умолчанию $CLAUDE_CODE_SESSION_ID.")
    parser.add_argument("--complete", action="store_true",
                        help="Явно подтвердить, что у сессии НЕТ хвоста (не ждём ответа/ревью, нет "
                             "недоделанного шага). Без флага пустые Следующий шаг/Не сделано/"
                             "Ждёт пользователя/Инфра → скрипт ОТКАЗЫВАЕТ (барьер): "
                             "статус complete должен быть решением, а не следствием незаполненного поля.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Показать итоговую карточку/фенс, ничего не записывая на диск "
                             "(CONTEXT.md/RESUME.md/архивы/commit пропускаются). Для проверки "
                             "поведения скрипта на реальном .planning/ без риска.")
    args = parser.parse_args()

    if args.body is not None:
        body = args.body
    else:
        if sys.stdin.isatty():
            print("ERROR: no body provided. Pipe body via stdin or use --body.", file=sys.stderr)
            return 2
        body = sys.stdin.read()

    body = body.strip()
    if not body:
        print("ERROR: block body is empty.", file=sys.stderr)
        return 2

    title = args.title.strip()
    date = dt.date.today().isoformat()

    sid = args.sid or session_id()
    routed_to_session = False
    # Путь даёт session-resolve.sh (тот же алгоритм, что READ) — WRITE/READ не разъедутся.
    resolved = resolver_planning(Path.cwd())
    if resolved:
        planning = Path(resolved)
        mode = "resolver"
        # --sid из НЕ-worktree (свой worktree исчез): резолвер из main вернёт корневой
        # .planning → дописать sessions/<sid>, чтобы карточка легла в стабильный session-dir.
        if args.sid and "/sessions/" not in resolved:
            planning = planning / "sessions" / args.sid
        routed_to_session = "/sessions/" in str(planning)
    else:
        # резолвер недоступен → прежний walk-up (обратная совместимость)
        planning, mode = find_planning_dir()
        if args.sid:
            planning = planning / "sessions" / args.sid
            routed_to_session = True
    if routed_to_session:
        planning.mkdir(parents=True, exist_ok=True)
    print(f"planning: {planning} ({mode})")

    # Пишем в ОБЩИЙ корневой .planning/ (не изолированный session-subdir)
    # → проверяем, что не затираем активную параллельную сессию. Guard возвращает путь:
    # корневой (свободен / владелец мёртв) либо sessions/<sid> (владелец жив).
    if not routed_to_session:
        planning = guard_root_resume_owner(planning, sid, title)
        if "/sessions/" in str(planning):
            routed_to_session = True
            planning.mkdir(parents=True, exist_ok=True)
            print(f"planning: {planning} (guard → session-scope)")

    # Barrier: empty tail fields without explicit --complete -> refuse BEFORE any write.
    # `complete` must be a decision, not the result of a forgotten field.
    body, _ = slim_body(body)  # канонизирует EN-алиасы до проверки полей
    if compute_status(field(body, "Следующий шаг"), field(body, "Не сделано"),
                      field(body, "Ждёт пользователя"), field(body, "Инфра")) == "complete" \
            and not args.complete:
        print(
            "⛔ Отказ: все поля пусты (Следующий шаг / Не сделано / Ждёт пользователя / Инфра) "
            "→ статус ушёл бы в complete, и trigger-блок «продолжаем …» НЕ был бы напечатан.\n\n"
            "Check the session tail:\n"
            "  • ждём ответа/ревью/ок юзера/ручного действия → заполни «Ждёт пользователя:»\n"
            "  • есть незавершённый шаг → заполни «Следующий шаг:» (конкретно: file:line / команда)\n"
            "  • нужен deploy/reload/ручное действие над инфрой → «Инфра:»\n\n"
            "complete = у сессии НЕТ хвоста (НЕ «фича верифицирована»). Если хвоста правда нет — "
            "перезапусти с флагом --complete, это осознанное подтверждение.",
            file=sys.stderr)
        return 4

    context_path = planning / "CONTEXT.md"
    existing = context_path.read_text() if context_path.exists() else ""
    preamble, active, archived = split_active_archived(existing)

    new_block = build_block(title, body, date)
    active.insert(0, new_block.rstrip())

    if args.dry_run:
        print("--dry-run: nothing written (CONTEXT.md/RESUME.md/archives/commit skipped)")
        archived_summary = []
        resume_content = build_resume(active[0], planning, sid)
    else:
        flushed_summary = flush_archived_to_files(planning, archived)
        archived_summary = rotate_archive(planning, active)
        archived_summary = flushed_summary + archived_summary
        write_context(planning, preamble, active, archived)
        print(f"✓ CONTEXT.md updated (block: {title})")
        if archived_summary:
            for fname, count in archived_summary:
                print(f"✓ archived {count} block(s) → {fname}")

        resume_content = build_resume(active[0], planning, sid)
        write_resume(planning, resume_content)
        print("✓ RESUME.md regenerated")

    files_to_commit: list[Path] = [context_path, planning / "RESUME.md"]
    for fname, _ in archived_summary:
        files_to_commit.append(planning / fname)

    _next_raw = field(active[0], "Следующий шаг")
    _blockers_raw = field(active[0], "Не сделано")
    _avoid = field(active[0], "Что не сработало")
    _infra = field(active[0], "Инфра")
    _human_pending = field(active[0], "Ждёт пользователя")
    _done = flatten_field(field(active[0], "Сделано"), limit=700)
    _files = list_field(active[0], "Файлы")
    _integ, _branch = compute_integration_status(planning, Path.cwd())
    _worktree = str(Path.cwd()) if in_worktree(Path.cwd()) else None
    _status = compute_status(_next_raw, _blockers_raw, _human_pending, _infra)
    print_session_card(title, _status, _next_raw or "-", _blockers_raw or "-", _avoid, _infra, _human_pending,
                       done=_done, files=_files, resume_path=str(planning / "RESUME.md"),
                       branch=_branch if _integ == "pending" else None, worktree=_worktree)

    if in_worktree(Path.cwd()):
        sid = session_id()
        sid_label = sid[:8] if sid else "?"
        print(f"worktree session {sid_label}: when done, merge the branch with `wt merge`")

    if not args.commit:
        return 0

    if args.dry_run:
        print("🔍 --dry-run: git commit пропущен")
        return 0

    ok, msg = git_commit(planning, files_to_commit, title)
    print(("✓ " if ok else "• ") + msg)

    return 0 if ok or msg in {"no git — skipped commit", "no changes to commit"} else 1


if __name__ == "__main__":
    sys.exit(main())

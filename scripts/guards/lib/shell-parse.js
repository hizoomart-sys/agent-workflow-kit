// Разбор bash-строки на КОМАНДЫ по правилам шелла — для барьеров, которые обязаны
// отличать запуск скрипта от упоминания его имени.
//
// Why a separate module: splitting on `| ; &&` without tracking quotes breaks quoted
// patterns (`grep "a\|b" file | head`) into bogus commands, and an unknown first word
// would be taken for a launch. This parser tracks quotes, heredocs and substitutions.
//
// Контракт:
//   parseCommand(str) -> { segments, unbalanced }
//   segments — массив команд; команда — массив токенов { text, bare }:
//     text — то, что увидит шелл (кавычки сняты),
//     bare — только НЕзакавыченные символы. Имя внутри кавычек — данные, а не команда.
//   Содержимое подстановок $( ) и `` разбирается как самостоятельные команды и попадает
//   в тот же список segments.
//   unbalanced=true — кавычка не закрыта; вызывающий обязан считать разбор ненадёжным
//   и работать по fail-closed, а не доверять «данным в кавычках».

const SUBST_DEPTH_LIMIT = 6;

// Тело heredoc — ДАННЫЕ: строки внутри него шелл не исполняет.
// Вырезаем от строки с оператором до строки-терминатора. Спрятать запуск этим нельзя:
// сам заголовок (`cat >> x << EOF`) остаётся и разбирается как обычно.
function stripHeredocs(cmd) {
  const lines = String(cmd).split("\n");
  const out = [];
  let terminator = null;
  for (const line of lines) {
    if (terminator !== null) {
      if (line.trim() === terminator) terminator = null;
      continue;
    }
    out.push(line);
    const m = line.match(/<<-?\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\1/);
    if (m) terminator = m[2];
  }
  return out.join("\n");
}

// Найти конец подстановки: i указывает на '(' после '$', либо на открывающий бэктик.
function readSubstitution(s, start, opener) {
  if (opener === "`") {
    let i = start + 1;
    while (i < s.length) {
      if (s[i] === "\\") { i += 2; continue; }
      if (s[i] === "`") return { inner: s.slice(start + 1, i), next: i + 1 };
      i++;
    }
    return { inner: s.slice(start + 1), next: s.length };
  }
  // $( … ) или <( … ) / >( … ): считаем вложенные скобки, кавычки внутри игнорируем как данные
  let i = start + 2;
  let depth = 1;
  let quote = null;
  while (i < s.length) {
    const ch = s[i];
    if (quote) {
      if (ch === "\\" && quote === '"') { i += 2; continue; }
      if (ch === quote) quote = null;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; i++; continue; }
    if (ch === "(") depth++;
    else if (ch === ")") { depth--; if (depth === 0) return { inner: s.slice(start + 2, i), next: i + 1 }; }
    i++;
  }
  return { inner: s.slice(start + 2), next: s.length };
}

function parseSegments(src, depth, acc) {
  const s = String(src);
  const segments = acc || [];
  let seg = [];
  let tok = null;
  let unbalanced = false;

  const endTok = () => { if (tok) { seg.push(tok); tok = null; } };
  const endSeg = () => { endTok(); if (seg.length) segments.push(seg); seg = []; };
  const add = (ch, quoted) => {
    if (!tok) tok = { text: "", bare: "" };
    tok.text += ch;
    if (!quoted) tok.bare += ch;
  };

  let i = 0;
  let quote = null;
  let prev = "";
  while (i < s.length) {
    const ch = s[i];

    if (quote === "'") {
      if (ch === "'") quote = null; else add(ch, true);
      i++; prev = ch; continue;
    }

    if (ch === "\\" && i + 1 < s.length) { add(s[i + 1], true); i += 2; prev = "\\"; continue; }

    // $(( … )) — арифметика, команд внутри нет
    if (ch === "$" && s[i + 1] === "(" && s[i + 2] === "(") {
      const close = s.indexOf("))", i + 3);
      i = close === -1 ? s.length : close + 2;
      endTok();
      prev = ")"; continue;
    }

    // подстановка команд: содержимое — самостоятельные команды
    if ((ch === "$" && s[i + 1] === "(") || ch === "`" ||
        ((ch === "<" || ch === ">") && s[i + 1] === "(" && quote !== '"')) {
      const { inner, next } = readSubstitution(s, i, ch === "`" ? "`" : "(");
      if (depth < SUBST_DEPTH_LIMIT) {
        const r = parseSegments(inner, depth + 1, segments);
        if (r.unbalanced) unbalanced = true;
      } else {
        unbalanced = true; // глубже не идём — не выдаём это за надёжный разбор
      }
      endTok();
      i = next; prev = ")"; continue;
    }

    if (quote === '"') {
      if (ch === '"') quote = null; else add(ch, true);
      i++; prev = ch; continue;
    }

    if (ch === '"' || ch === "'") { quote = ch; i++; prev = ch; continue; }

    if (ch === "\n" || ch === ";") { endSeg(); i++; prev = ch; continue; }
    if (ch === "&" && s[i + 1] === "&") { endSeg(); i += 2; prev = "&"; continue; }
    if (ch === "|" && s[i + 1] === "|") { endSeg(); i += 2; prev = "|"; continue; }
    if (ch === "|") { endSeg(); i++; prev = "|"; continue; }
    // одиночный `&`: разделитель, но не часть перенаправления (`2>&1`, `&>файл`)
    if (ch === "&" && prev !== ">" && prev !== "<" && s[i + 1] !== ">") { endSeg(); i++; prev = "&"; continue; }

    if (/\s/.test(ch)) { endTok(); i++; prev = ch; continue; }
    add(ch, false);
    i++; prev = ch;
  }
  endSeg();
  if (quote !== null) unbalanced = true;
  return { segments, unbalanced };
}

function parseCommand(cmd) {
  const { segments, unbalanced } = parseSegments(stripHeredocs(cmd), 0, null);
  return { segments, unbalanced };
}

// Наивный разбор старого образца — запасной путь, когда кавычки не сошлись:
// лучше лишний раз отбить, чем пропустить запуск.
function naiveSegments(cmd) {
  return stripHeredocs(cmd)
    .split(/&&|\|\||;|\||\n/)
    .map(part => part.trim().split(/\s+/).filter(Boolean).map(t => ({ text: t, bare: t })))
    .filter(tokens => tokens.length);
}

module.exports = { parseCommand, naiveSegments, stripHeredocs };

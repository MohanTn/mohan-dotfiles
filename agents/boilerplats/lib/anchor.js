'use strict';

// Where does a scaffold:inject marker belong in a file that has never been
// scaffolded? This is the brownfield half of the generator: legacy files are
// adopted one at a time, on the first touch, instead of being bulk-marked up
// front. The heuristic picks the end of the enclosing top-level block and the
// caller reports the chosen line back to the agent, which can override it with
// an explicit anchor. It never guesses when it cannot find a safe point —
// a marker in the wrong scope silently corrupts every later injection.

const DEFAULT_INDENT = {
  csharp: '    ',
  typescript: '  ',
  javascript: '  ',
  go: '\t',
  python: '    ',
  sh: '  ',
};

const BRACE_LANGS = new Set(['csharp', 'typescript', 'javascript', 'go']);

class AnchorError extends Error {
  constructor(message, candidates) {
    super(message);
    this.candidates = candidates || [];
  }
}

function indentOf(line) {
  const m = line.match(/^([ \t]+)/);
  return m ? m[1] : '';
}

// Indentation for a marker inserted at `index`: reuse the last non-empty line
// above it that is actually indented, so the marker sits at member level.
function inferIndent(lines, index, lang) {
  for (let i = index - 1; i >= 0; i--) {
    if (!lines[i].trim()) continue;
    const ind = indentOf(lines[i]);
    if (ind) return ind;
    break;
  }
  return DEFAULT_INDENT[lang] || '  ';
}

// Brace languages: the marker goes just above the closing brace of the LAST
// top-level block (`}` / `};` / `})` in column 0) — the end of the class,
// struct-method set, or router factory the file is built around.
function braceAnchor(lines, lang) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (/^\}[;,)]*\s*$/.test(lines[i])) {
      return { index: i, indent: inferIndent(lines, i, lang) };
    }
  }
  throw new AnchorError(
    'No top-level closing brace found to anchor the scaffold:inject marker. ' +
      'Pass an explicit anchor (a line number, or a unique snippet the marker should precede).',
    lines.map((l, i) => ({ line: i + 1, text: l })).filter((l) => l.text.trim().endsWith('}')).slice(-5)
  );
}

// Python: if the file's last top-level construct is a class, the marker goes
// at the end of that class body (so later injections are methods). Otherwise
// the file is module-shaped — like the FastAPI controller template, whose own
// marker sits at column 0 — and the marker goes at module scope.
function pythonAnchor(lines) {
  let lastClass = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^class\s+\w+/.test(lines[i])) lastClass = i;
  }

  const lastCode = lastNonEmpty(lines);
  if (lastCode === -1) {
    throw new AnchorError('File is empty, nothing to anchor a scaffold:inject marker to.', []);
  }

  if (lastClass !== -1) {
    // Does anything at column 0 follow the class? If so the class body ended
    // and the file is module-shaped from there on.
    let moduleCodeAfter = false;
    for (let i = lastClass + 1; i < lines.length; i++) {
      const l = lines[i];
      if (!l.trim() || /^\s/.test(l)) continue;
      if (/^#/.test(l)) continue;
      moduleCodeAfter = true;
      break;
    }
    if (!moduleCodeAfter) {
      let indent = DEFAULT_INDENT.python;
      for (let i = lastClass + 1; i < lines.length; i++) {
        if (lines[i].trim() && /^\s/.test(lines[i])) {
          indent = indentOf(lines[i]);
          break;
        }
      }
      return { index: lastCode + 1, indent };
    }
  }
  return { index: lastCode + 1, indent: '' };
}

// Shell: above the `main "$@"` call when the file follows the script template's
// shape, else at the end.
function shAnchor(lines) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (/^main\s+"\$@"/.test(lines[i])) {
      return { index: i, indent: '' };
    }
  }
  const lastCode = lastNonEmpty(lines);
  if (lastCode === -1) {
    throw new AnchorError('File is empty, nothing to anchor a scaffold:inject marker to.', []);
  }
  return { index: lastCode + 1, indent: '' };
}

function lastNonEmpty(lines) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) return i;
  }
  return -1;
}

// Explicit override: a 1-based line number, or a unique snippet. Either way
// the marker is inserted directly ABOVE the resolved line.
function resolveAnchor(lines, anchor, lang) {
  if (typeof anchor === 'number' || /^\d+$/.test(String(anchor))) {
    const line = Number(anchor);
    if (line < 1 || line > lines.length + 1) {
      throw new AnchorError(`Anchor line ${line} is outside the file (1-${lines.length}).`, []);
    }
    return { index: line - 1, indent: inferIndent(lines, line - 1, lang) };
  }

  const snippet = String(anchor);
  const hits = [];
  lines.forEach((l, i) => {
    if (l.includes(snippet)) hits.push(i);
  });
  if (hits.length === 0) {
    throw new AnchorError(`Anchor snippet not found in the file: ${snippet}`, []);
  }
  if (hits.length > 1) {
    throw new AnchorError(
      `Anchor snippet is not unique (${hits.length} matches), pass a line number instead: ${snippet}`,
      hits.map((i) => ({ line: i + 1, text: lines[i] }))
    );
  }
  return { index: hits[0], indent: inferIndent(lines, hits[0], lang) };
}

function findAnchor(lang, content, anchor) {
  const lines = content.split('\n');
  if (anchor !== undefined && anchor !== null && anchor !== '') {
    return resolveAnchor(lines, anchor, lang);
  }
  if (BRACE_LANGS.has(lang)) return braceAnchor(lines, lang);
  if (lang === 'python') return pythonAnchor(lines);
  if (lang === 'sh') return shAnchor(lines);
  throw new AnchorError(`No anchor heuristic for language "${lang}", pass an explicit anchor.`, []);
}

module.exports = { findAnchor, resolveAnchor, AnchorError, DEFAULT_INDENT };

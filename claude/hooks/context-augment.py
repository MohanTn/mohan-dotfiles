#!/usr/bin/env python3
"""UserPromptSubmit hook: condense the prompt and inject repo context.

Reads the Claude Code hook JSON on stdin, extracts keywords from the prompt
(paths, CamelCase/ALL_CAPS symbols, bare extensions), locates the most relevant
files with fzf fuzzy filename matching + ripgrep definition search, and emits
an *abstract* of each file (signatures via AST for Python, regex for other
languages) wrapped in `<file>` XML tags.

Design patterns:
  1. Tagging      -- each file's context is bounded by `<file path=...>` tags.
  2. Abstract     -- pull class/def signatures, not the first N raw lines.
  3. Keyword-driven -- searches are triggered by tokens found in the prompt.

Always exits 0; failures degrade to no augmentation rather than blocking submit.
"""
from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys
import time

# --- tunables -----------------------------------------------------------------
MIN_WORDS = 4            # skip trivial / conversational prompts
MAX_KEYWORDS = 8         # cap search fan-out
MAX_FILES = 6            # cap injected files
MAX_FILE_CHARS = 1500    # per-file abstract budget
TOTAL_BUDGET = 8000      # overall augmentation budget
SEARCH_TIMEOUT = 2       # seconds per rg/fd call
SEARCH_DEADLINE = 4      # seconds total wall-clock budget for all searches

CODE_EXTS = ("py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "rb",
             "c", "cc", "cpp", "h", "hpp", "sh", "lua", "php", "cs")

# tokens that look like paths / filenames (optionally @-prefixed)
PATH_RE = re.compile(r"@?((?:[\w.\-]+/)+[\w.\-]+|\b[\w.\-]+\.[a-zA-Z]{1,5}\b)")
# CamelCase (AuthService), ALL_CAPS (MAX_RETRY), snake_case (get_user)
SYMBOL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")
EXT_RE = re.compile(r"\.(" + "|".join(CODE_EXTS) + r")\b")

STOPWORDS = {
    "The", "This", "That", "With", "From", "Into", "When", "Then", "Also",
    "And", "But", "For", "Not", "Use", "Using", "Add", "Fix", "Make", "Get",
    "Set", "Run", "Should", "Would", "Could", "Please", "Need", "Want", "How",
    "What", "Why", "Where", "AI", "OK",
}


def run(cmd: list[str], cwd: str) -> list[str]:
    """Run a command, return stdout lines, never raise."""
    try:
        out = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True,
            timeout=SEARCH_TIMEOUT, check=False,
        )
        return [ln for ln in out.stdout.splitlines() if ln.strip()]
    except (subprocess.SubprocessError, OSError):
        return []


def extract_keywords(prompt: str) -> tuple[list[str], list[str]]:
    """Return (path_hints, symbol_hints) drawn from the prompt."""
    paths, symbols = [], []
    seen_p, seen_s = set(), set()

    for m in PATH_RE.finditer(prompt):
        p = m.group(1).lstrip("@")
        if p not in seen_p:
            seen_p.add(p)
            paths.append(p)

    for m in SYMBOL_RE.finditer(prompt):
        tok = m.group(1)
        if tok in seen_s or tok in STOPWORDS or len(tok) < 3:
            continue
        # keep code-shaped identifiers: CamelCase, ALL_CAPS, snake_case, or long lowercase words
        is_camel = any(c.isupper() for c in tok[1:]) and any(c.islower() for c in tok)
        is_caps = tok.isupper()
        is_snake = "_" in tok
        is_long_word = len(tok) >= 5  # accept long lowercase words (repo, boilerplates, etc.)
        if is_camel or is_caps or is_snake or is_long_word:
            seen_s.add(tok)
            symbols.append(tok)

    return paths[:MAX_KEYWORDS], symbols[:MAX_KEYWORDS]


def repo_root(cwd: str) -> str:
    lines = run(["git", "rev-parse", "--show-toplevel"], cwd)
    return lines[0] if lines else cwd


def fuzzy_filter(query: str, candidates: list[str], root: str, limit: int) -> list[str]:
    """Fuzzy-rank candidates against query via `fzf --filter`, never raise."""
    if not query or not candidates:
        return []
    try:
        out = subprocess.run(
            ["fzf", "-i", "--filter", query],
            input="\n".join(candidates), cwd=root, capture_output=True, text=True,
            timeout=SEARCH_TIMEOUT, check=False,
        )
        return [ln for ln in out.stdout.splitlines() if ln.strip()][:limit]
    except (subprocess.SubprocessError, OSError):
        return []


def find_files(paths: list[str], symbols: list[str], root: str) -> list[str]:
    """Rank candidate files and dirs: explicit paths > fuzzy filename matches > symbol defs."""
    ranked: list[str] = []
    seen: set[str] = set()
    deadline = time.monotonic() + SEARCH_DEADLINE
    all_files: list[str] | None = None
    all_dirs: list[str] | None = None

    def expired() -> bool:
        return time.monotonic() > deadline

    def add(rel: str) -> None:
        rel = rel.strip()
        if rel and rel not in seen and os.path.exists(os.path.join(root, rel)):
            seen.add(rel)
            ranked.append(rel)

    def file_list() -> list[str]:
        nonlocal all_files
        if all_files is None:
            all_files = run(["fd", "-t", "f"], root)
        return all_files

    def dir_list() -> list[str]:
        nonlocal all_dirs
        if all_dirs is None:
            all_dirs = run(["fd", "-t", "d"], root)
        return all_dirs

    # 1. explicit paths (exact, else fuzzy-matched by basename)
    for p in paths:
        if expired():
            break
        if os.path.isfile(os.path.join(root, p)):
            add(p)
        else:
            base = os.path.basename(p)
            for hit in fuzzy_filter(base, file_list(), root, limit=3):
                add(hit)

    # 2. filenames fuzzy-matching a symbol (AuthService ~ auth_service.py, authSvc.ts)
    for sym in symbols:
        if expired() or len(ranked) >= MAX_FILES:
            break
        for hit in fuzzy_filter(sym, file_list(), root, limit=3):
            add(hit)

    # 2b. directory names fuzzy-matching a symbol (boilerplates ~ agents/boilerplats/)
    for sym in symbols:
        if expired() or len(ranked) >= MAX_FILES:
            break
        for hit in fuzzy_filter(sym, dir_list(), root, limit=2):
            add(hit)

    # 3. definition sites of a symbol via ripgrep
    for sym in symbols:
        if expired() or len(ranked) >= MAX_FILES:
            break
        esc = re.escape(sym)
        hits = run(
            ["rg", "-l", "-i",
             "-e", rf"(class|def|function|func|struct|interface|type)\s+{esc}",
             "-e", rf"{esc}\s*[:=]\s*(function|\()"],
            root,
        )
        for hit in hits:
            add(hit)

    return ranked[:MAX_FILES]


def abstract_python(src: str) -> str:
    """Emit imports + class/function signatures with first docstring line."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return abstract_regex(src)

    out: list[str] = []

    def firstdoc(node) -> str:
        doc = ast.get_docstring(node)
        return f'  """{doc.strip().splitlines()[0]}"""' if doc else ""

    def sig(node) -> str:
        try:
            args = ast.unparse(node.args)
        except Exception:
            args = "..."
        ret = f" -> {ast.unparse(node.returns)}" if getattr(node, "returns", None) else ""
        kw = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
        return f"{kw} {node.name}({args}){ret}:"

    imports = [ln.rstrip() for ln in src.splitlines()
               if ln.startswith(("import ", "from "))]
    if imports:
        out.append("# imports")
        out.extend(imports[:12])
        out.append("")

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            bases = ", ".join(ast.unparse(b) for b in node.bases)
            out.append(f"class {node.name}({bases}):" if bases else f"class {node.name}:")
            d = firstdoc(node)
            if d:
                out.append(d)
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    out.append("  " + sig(sub))
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            out.append(sig(node))
            d = firstdoc(node)
            if d:
                out.append(d.lstrip())

    return "\n".join(out).strip()


DEF_LINE_RE = re.compile(
    r"^\s*(export\s+)?(public\s+|private\s+|protected\s+|static\s+|async\s+)*"
    r"(class|interface|type|enum|struct|impl|trait|func|function|def|fn|"
    r"const|let|var|public|private)\b.*"
)


def abstract_regex(src: str) -> str:
    """Language-agnostic fallback: keep definition-shaped lines only."""
    out: list[str] = []
    for ln in src.splitlines():
        if DEF_LINE_RE.match(ln):
            out.append(ln.rstrip().rstrip("{").rstrip())
    return "\n".join(dict.fromkeys(out)).strip()


def abstract_file(root: str, rel: str) -> str:
    path = os.path.join(root, rel)
    # Handle directories: list their contents
    if os.path.isdir(path):
        try:
            items = sorted(os.listdir(path))[:30]
            return "Directory:\n" + "\n".join(f"  {item}" for item in items)
        except OSError:
            return ""
    # Handle files: extract structure
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return ""
    body = abstract_python(src) if rel.endswith(".py") else abstract_regex(src)
    if not body:
        # nothing structural found: fall back to a short head
        body = "\n".join(src.splitlines()[:20]).strip()
    if len(body) > MAX_FILE_CHARS:
        body = body[:MAX_FILE_CHARS].rstrip() + "\n... (truncated)"
    return body


def condense_prompt(prompt: str) -> str:
    """Whitespace-normalized, length-capped restatement."""
    flat = re.sub(r"\s+", " ", prompt).strip()
    return flat[:400] + (" ..." if len(flat) > 400 else "")


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    prompt = (data.get("prompt") or "").strip()
    cwd = data.get("cwd") or os.getcwd()
    if len(prompt.split()) < MIN_WORDS:
        return 0

    paths, symbols = extract_keywords(prompt)
    if not paths and not symbols:
        return 0

    root = repo_root(cwd)
    files = find_files(paths, symbols, root)
    if not files:
        return 0

    parts = ["<context-augmentation>"]
    parts.append(f"<condensed_prompt>{condense_prompt(prompt)}</condensed_prompt>")
    kw = ", ".join(paths + symbols)
    parts.append(f"<keywords>{kw}</keywords>")

    used = sum(len(p) for p in parts)
    for rel in files:
        body = abstract_file(root, rel)
        if not body:
            continue
        lang = rel.rsplit(".", 1)[-1] if "." in rel else "txt"
        block = f'<file path="{rel}" lang="{lang}">\n{body}\n</file>'
        if used + len(block) > TOTAL_BUDGET:
            break
        parts.append(block)
        used += len(block)

    if len(parts) <= 3:  # header only, no file blocks
        return 0

    parts.append("</context-augmentation>")
    print("\n".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""UserPromptSubmit hook: condense the prompt and inject repo context.

Reads the Claude Code hook JSON on stdin, extracts keywords from the prompt
(paths, CamelCase/ALL_CAPS symbols, bare extensions), locates the most relevant
files with fzf fuzzy filename matching + ripgrep definition search, and emits
each file wrapped in `<file>` XML tags at a size-appropriate fidelity.

Design patterns:
  1. Tagging      -- each file's context is bounded by `<file path=...>` tags.
  2. Tiered       -- small files inject as full minified content (no follow-up
                     Read needed); larger files degrade to signatures only.
  3. Keyword-driven -- searches are triggered by tokens found in the prompt.

Injection is advisory only: nothing here restricts a later Read. "full" content
is minified (comments stripped), so a Read of the same file is not redundant.

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
MINIFY_RAW_CAP = 20000   # skip full-content tier above this raw file size
MINIFY_MAX_CHARS = 2500  # inject full minified content only if it fits this
TOTAL_BUDGET = 8000      # overall augmentation budget
SEARCH_TIMEOUT = 2       # seconds per rg/fd call
SEARCH_DEADLINE = 4      # seconds total wall-clock budget for all searches
MAX_CANDIDATES = 20000   # cap the fd file/dir list so fzf stays fast on monorepos
MIN_WORD_LEN = 8         # bare lowercase words shorter than this are prose, not symbols

# per-language single-line comment prefix, for safe whitespace-only minify
LINE_COMMENT = {
    "py": "#", "sh": "#", "rb": "#", "yaml": "#", "yml": "#", "toml": "#",
    "js": "//", "ts": "//", "tsx": "//", "jsx": "//", "go": "//", "rs": "//",
    "java": "//", "c": "//", "cc": "//", "cpp": "//", "h": "//", "hpp": "//",
    "php": "//", "cs": "//", "lua": "--",
}

CODE_EXTS = ("py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "rb",
             "c", "cc", "cpp", "h", "hpp", "sh", "lua", "php", "cs")

# tokens that look like paths / filenames (optionally @-prefixed)
PATH_RE = re.compile(r"@?((?:[\w.\-]+/)+[\w.\-]+|\b[\w.\-]+\.[a-zA-Z]{1,5}\b)")
# CamelCase (AuthService), ALL_CAPS (MAX_RETRY), snake_case (get_user)
SYMBOL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")
EXT_RE = re.compile(r"\.(" + "|".join(CODE_EXTS) + r")\b")

# Matched case-insensitively (see extract_keywords), so list these in one form.
STOPWORDS = {
    "the", "this", "that", "with", "from", "into", "when", "then", "also",
    "and", "but", "for", "not", "use", "using", "add", "fix", "make", "get",
    "set", "run", "should", "would", "could", "please", "need", "want", "how",
    "what", "why", "where", "ai", "ok",
    # long prose words that clear MIN_WORD_LEN but never name code
    "actually", "anything", "basically", "probably", "something", "everything",
    "existing", "complete", "complex", "honest", "review", "reviewed",
    "suggestion", "suggestions", "understand", "currently", "instead",
    "because", "however", "therefore", "consider", "explain", "describe",
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
        if tok in seen_s or tok.lower() in STOPWORDS or len(tok) < 3:
            continue
        # keep code-shaped identifiers: CamelCase, ALL_CAPS, snake_case, or long lowercase words
        is_camel = any(c.isupper() for c in tok[1:]) and any(c.islower() for c in tok)
        is_caps = tok.isupper()
        is_snake = "_" in tok
        # A bare lowercase word is only worth searching when it's long enough to
        # plausibly be an identifier; shorter ones are ordinary prose and just
        # burn the fzf/rg budget on noise.
        is_long_word = len(tok) >= MIN_WORD_LEN
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

    def add_dir_contents(dir_path: str) -> None:
        """Recursively add files from a directory, respecting MAX_FILES limit."""
        try:
            for entry in os.listdir(os.path.join(root, dir_path)):
                if len(ranked) >= MAX_FILES or expired():
                    break
                entry_rel = os.path.join(dir_path, entry)
                entry_full = os.path.join(root, entry_rel)
                if os.path.isfile(entry_full):
                    add(entry_rel)
                elif os.path.isdir(entry_full) and not entry.startswith('.'):
                    add_dir_contents(entry_rel)
        except (OSError, PermissionError):
            pass

    def file_list() -> list[str]:
        nonlocal all_files
        if all_files is None:
            all_files = run(["fd", "-t", "f"], root)[:MAX_CANDIDATES]
        return all_files

    def dir_list() -> list[str]:
        nonlocal all_dirs
        if all_dirs is None:
            all_dirs = run(["fd", "-t", "d"], root)[:MAX_CANDIDATES]
        return all_dirs

    # 1. explicit paths (exact, else fuzzy-matched by basename)
    for p in paths:
        if expired() or len(ranked) >= MAX_FILES:
            break
        full_p = os.path.join(root, p)
        if os.path.isfile(full_p):
            add(p)
        elif os.path.isdir(full_p):
            add_dir_contents(p)
        else:
            base = os.path.basename(p)
            for hit in fuzzy_filter(base, file_list(), root, limit=3):
                if os.path.isdir(os.path.join(root, hit)):
                    add_dir_contents(hit)
                else:
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
            add_dir_contents(hit)

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


def minify_code(src: str, lang: str) -> str:
    """Drop blank lines and full-line comments; safe whitespace-only compression.

    Preserves code and string/docstring content verbatim (comment stripping only
    fires on lines whose first non-space char is the comment prefix), so the
    result is the whole file minus noise, not an abstract.
    """
    prefix = LINE_COMMENT.get(lang)
    out: list[str] = []
    for ln in src.splitlines():
        stripped = ln.strip()
        if not stripped:
            continue
        if prefix and stripped.startswith(prefix):
            continue
        out.append(ln.rstrip())
    return "\n".join(out)


def render_file(root: str, rel: str) -> tuple[str, str]:
    """Return (body, mode): 'dir' listing, 'full' minified content, or 'abstract'.

    Small files inject as full minified content so no follow-up Read is needed;
    larger files degrade to a signature-only abstract.
    """
    path = os.path.join(root, rel)
    # Directories: list their contents
    if os.path.isdir(path):
        try:
            items = sorted(os.listdir(path))[:30]
            return "Directory:\n" + "\n".join(f"  {item}" for item in items), "dir"
        except OSError:
            return "", "dir"
    # Files: read once, then pick a tier by size
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return "", "abstract"
    lang = rel.rsplit(".", 1)[-1] if "." in rel else "txt"
    # Tier 1: small file -> full minified content, no Read round-trip needed.
    if len(src) <= MINIFY_RAW_CAP:
        full = minify_code(src, lang)
        if full and len(full) <= MINIFY_MAX_CHARS:
            return full, "full"
    # Tier 2: larger file -> structural abstract only.
    body = abstract_python(src) if rel.endswith(".py") else abstract_regex(src)
    if not body:
        # nothing structural found: fall back to a short head
        body = "\n".join(src.splitlines()[:20]).strip()
    if len(body) > MAX_FILE_CHARS:
        body = body[:MAX_FILE_CHARS].rstrip() + "\n... (truncated)"
    return body, "abstract"


def condense_prompt(prompt: str) -> str:
    """Whitespace-normalized, length-capped restatement."""
    flat = re.sub(r"\s+", " ", prompt).strip()
    return flat[:400] + (" ..." if len(flat) > 400 else "")


def should_inject_repo_map_hint(prompt: str, paths: list[str], symbols: list[str]) -> bool:
    """Detect if prompt is about file discovery in tracked directories."""
    # Keywords that suggest file-discovery queries
    discovery_keywords = {
        "boilerplate", "scaffold", "template", "controller", "repository",
        "handler", "validator", "mapper", "hooks", "agents", "ls", "find",
        "structure", "layout", "what file", "which file", "list", "inventory"
    }
    prompt_lower = prompt.lower()
    for kw in discovery_keywords:
        if kw in prompt_lower:
            return True
    # Or if querying paths that are in tracked dirs
    tracked_dirs = {"agents/boilerplats", "claude/hooks", "agents/skills"}
    for p in paths:
        for td in tracked_dirs:
            if td in p:
                return True
    return False


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

    # Inject repo-map-check skill reference if doing file discovery
    if should_inject_repo_map_hint(prompt, paths, symbols):
        parts.append("<skill name=\"repo-map-check\">Check .claude/repo-map.md for cached file inventory before running filesystem queries.</skill>")

    header_count = len(parts)
    used = sum(len(p) for p in parts)
    for rel in files:
        body, mode = render_file(root, rel)
        if not body:
            continue
        lang = rel.rsplit(".", 1)[-1] if "." in rel else "txt"
        block = f'<file path="{rel}" lang="{lang}" mode="{mode}">\n{body}\n</file>'
        if used + len(block) > TOTAL_BUDGET:
            break
        parts.append(block)
        used += len(block)

    if len(parts) <= header_count:  # header only, no file blocks
        return 0

    parts.append("</context-augmentation>")
    print("\n".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())

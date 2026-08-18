#!/usr/bin/env python3
"""session-audit.py — reconstruct one Claude Code session into a single readable
audit file: the system-prompt layer, then a chronological trace of every user
prompt, every hook injection (UserPromptSubmit / SessionStart / Pre/PostToolUse /
Stop ...), the assistant's response, and every tool call + result.

Claude Code stores each session as append-ordered JSONL under
~/.claude/projects/<cwd-slug>/<session-id>.jsonl. Hook output that gets surfaced
to the model is recorded as `attachment` lines of type `hook_success` carrying
{hookEvent, hookName, command, stdout, stderr, exitCode, durationMs} — that is
the ground truth of "what a hook injected". Blocking hooks (exit 2) don't produce
a hook_success line; their stderr comes back as an errored tool_result, which is
rendered here too.

The base system prompt is not stored in the transcript. The user-controlled
system layer IS: the CLAUDE.md -> AGENTS.md import chain plus the SessionStart
hook digest. Both are surfaced at the top.

Usage:
  session-audit.py [transcript.jsonl] [--out FILE] [--full] [--cwd DIR]
    (no transcript) -> most recent session for --cwd (default: $PWD)
    --out FILE       -> write there (default: stdout)
    --full           -> do not truncate injected text / tool IO
"""
import argparse
import json
import os
import sys
from datetime import datetime

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")


def slugify_cwd(cwd: str) -> str:
    # Claude Code's project dir name is the abs path with every non-alnum -> '-'.
    return "".join(c if c.isalnum() else "-" for c in cwd)


def find_latest_transcript(cwd: str):
    slug = slugify_cwd(os.path.abspath(cwd))
    proj = os.path.join(PROJECTS, slug)
    if not os.path.isdir(proj):
        return None
    jsonls = [
        os.path.join(proj, f) for f in os.listdir(proj) if f.endswith(".jsonl")
    ]
    if not jsonls:
        return None
    return max(jsonls, key=os.path.getmtime)


def load(path: str):
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def clip(text, limit, full):
    if text is None:
        return ""
    text = str(text)
    if full or len(text) <= limit:
        return text
    return text[:limit] + f"\n… [+{len(text) - limit} chars truncated]"


def fmt_ts(ts):
    if not ts:
        return ""
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime(
            "%H:%M:%S"
        )
    except Exception:
        return ts


def indent(text, prefix="    "):
    return "\n".join(prefix + ln for ln in str(text).splitlines())


# ---- system-prompt layer (user-controlled config, not the base prompt) -------

def read_system_layer():
    """Resolve the CLAUDE.md -> @import chain into one blob so the audit shows
    exactly the standing instructions that prefix every turn."""
    out = []
    claude_md = os.path.join(HOME, ".claude", "CLAUDE.md")
    seen = set()

    def resolve(path, depth=0):
        path = os.path.abspath(os.path.expanduser(path))
        if path in seen or depth > 5 or not os.path.isfile(path):
            return
        seen.add(path)
        with open(path, "r", encoding="utf-8") as fh:
            body = fh.read()
        out.append((path, body))
        for ln in body.splitlines():
            s = ln.strip()
            if s.startswith("@"):
                resolve(s[1:].strip(), depth + 1)

    resolve(claude_md)
    return out


# ---- hook inventory across all three agents (from the dotfiles config) -------

DOTFILES = os.path.join(HOME, "REPO", "mohan-dotfiles")


def hook_inventory():
    """Enumerate configured hooks per agent, event -> command, straight from the
    repo config so the audit shows the full landscape (including hooks that did
    not fire this session)."""
    agents = {}

    # Claude Code: claude/settings.json
    claude_cfg = os.path.join(DOTFILES, "claude", "settings.json")
    if os.path.isfile(claude_cfg):
        try:
            cfg = json.load(open(claude_cfg, encoding="utf-8"))
            rows = []
            for event, groups in (cfg.get("hooks") or {}).items():
                for g in groups:
                    matcher = g.get("matcher", "*")
                    for h in g.get("hooks", []):
                        cmd = h.get("command", "").split("/")[-1].strip('" ')
                        rows.append((event, matcher, cmd))
            agents["Claude Code (settings.json)"] = rows
        except Exception:
            pass

    # Copilot CLI: copilot/hooks/mohan-hooks.json
    cop_cfg = os.path.join(DOTFILES, "copilot", "hooks", "mohan-hooks.json")
    if os.path.isfile(cop_cfg):
        try:
            cfg = json.load(open(cop_cfg, encoding="utf-8"))
            rows = []
            for event, arr in (cfg.get("hooks") or {}).items():
                for h in arr:
                    cmd = (h.get("bash", "") or "").split("/")[-1].strip('" ')
                    rows.append((event, "*", cmd))
            agents["Copilot CLI (mohan-hooks.json)"] = rows
        except Exception:
            pass

    # Pi: TS extension registers events via pi.on(...) — grep for them
    pi_idx = os.path.join(DOTFILES, "pi", "agent", "extensions", "hooks", "index.ts")
    if os.path.isfile(pi_idx):
        rows = []
        for ln in open(pi_idx, encoding="utf-8"):
            s = ln.strip()
            if "pi.on(" in s:
                ev = s.split("pi.on(", 1)[1].split(")")[0].split(",")[0].strip("\"'")
                rows.append((ev, "*", "index.ts handler"))
        if rows:
            agents["Pi (extensions/hooks/index.ts)"] = rows

    return agents


# ---- rendering ---------------------------------------------------------------

def render(rows, args):
    L = []
    w = L.append

    w("# Session Audit\n")
    w(f"- Transcript: `{args._transcript}`")
    w(f"- Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    counts = {}
    for r in rows:
        counts[r.get("type", "?")] = counts.get(r.get("type", "?"), 0) + 1
    w(f"- Rows: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    hook_fires = sum(
        1
        for r in rows
        if r.get("type") == "attachment"
        and r.get("attachment", {}).get("type") == "hook_success"
    )
    w(f"- Hook injections recorded: {hook_fires}\n")

    # -- System-prompt layer --
    w("---\n\n## 1. System-prompt layer (standing instructions)\n")
    w(
        "> The base model system prompt is not stored in the transcript. What "
        "follows is the user-controlled layer that prefixes every turn: the "
        "`~/.claude/CLAUDE.md` @import chain.\n"
    )
    for path, body in read_system_layer():
        w(f"### `{path}`\n")
        w("```markdown")
        w(clip(body.rstrip(), 4000, args.full))
        w("```\n")

    # -- Hook inventory --
    w("---\n\n## 2. Configured hook inventory (all agents)\n")
    w(
        "> Every hook wired in the dotfiles, per agent and event — including "
        "hooks that did not fire this session. Section 3 shows which actually "
        "ran.\n"
    )
    inv = hook_inventory()
    if not inv:
        w("_No hook config found under `~/REPO/mohan-dotfiles`._\n")
    for agent, hrows in inv.items():
        w(f"### {agent}\n")
        w("| Event | Matcher | Hook |")
        w("|---|---|---|")
        for event, matcher, cmd in hrows:
            w(f"| `{event}` | `{matcher}` | `{cmd}` |")
        w("")

    # -- Chronological trace --
    w("---\n\n## 3. Session trace (chronological)\n")

    turn = 0
    for r in rows:
        t = r.get("type")
        ts = fmt_ts(r.get("timestamp"))

        if t == "attachment":
            att = r.get("attachment", {})
            if att.get("type") == "hook_success":
                ev = att.get("hookEvent", "?")
                nm = att.get("hookName", "?")
                code = att.get("exitCode", 0)
                dur = att.get("durationMs", "")
                stdout = (att.get("stdout") or att.get("content") or "").strip()
                stderr = (att.get("stderr") or "").strip()
                w(f"🪝 **HOOK** `{ev}` / `{nm}`  (exit {code}, {dur}ms) — {ts}")
                if stdout:
                    w("  ↳ injected into context:")
                    w(indent(clip(stdout, 1200, args.full), "  > "))
                if stderr:
                    w("  ↳ stderr:")
                    w(indent(clip(stderr, 600, args.full), "  ! "))
                w("")
            continue

        if t == "user":
            content = r.get("message", {}).get("content")
            if isinstance(content, str):
                s = content.strip()
                # skip local-command scaffolding noise but keep real prompts
                if s.startswith("<local-command") or s.startswith(
                    "<command-name>"
                ):
                    label = "slash-command / local"
                    w(f"⌨️  **{label}** — {ts}")
                    w(indent(clip(s, 300, args.full), "    "))
                    w("")
                    continue
                turn += 1
                w(f"\n{'='*72}")
                w(f"🧑 **USER PROMPT** (turn {turn}) — {ts}")
                w(f"{'='*72}")
                w(indent(clip(s, 2000, args.full), "    "))
                w("")
            elif isinstance(content, list):
                for c in content:
                    if c.get("type") == "tool_result":
                        is_err = c.get("is_error", False)
                        body = c.get("content", "")
                        if isinstance(body, list):
                            body = "\n".join(
                                b.get("text", "") for b in body if isinstance(b, dict)
                            )
                        tag = "❌ TOOL RESULT (error)" if is_err else "📥 TOOL RESULT"
                        w(f"{tag}")
                        w(indent(clip(body, 800, args.full), "    | "))
                        w("")
            continue

        if t == "assistant":
            for c in r.get("message", {}).get("content", []):
                ct = c.get("type")
                if ct == "thinking":
                    think = (c.get("thinking") or "").strip()
                    if not think:
                        continue  # redacted/signature-only in stored transcripts
                    w(f"💭 *thinking* — {ts}")
                    w(indent(clip(think, 500, args.full), "    · "))
                    w("")
                elif ct == "text":
                    w(f"🤖 **ASSISTANT** — {ts}")
                    w(indent(clip(c.get("text", ""), 1500, args.full), "    "))
                    w("")
                elif ct == "tool_use":
                    name = c.get("name", "?")
                    inp = c.get("input", {})
                    # compact one-line arg preview
                    preview = json.dumps(inp, ensure_ascii=False)
                    w(f"🔧 **TOOL CALL** `{name}`")
                    w(indent(clip(preview, 700, args.full), "    $ "))
                    w("")
            continue

        if t == "system":
            sub = r.get("subtype", "")
            body = r.get("content")
            if sub in ("stop_hook_summary", "turn_duration"):
                continue
            if body:
                w(f"ℹ️  *{sub}* — {ts}")
                w(indent(clip(body, 300, args.full), "    "))
                w("")

    return "\n".join(L)


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("transcript", nargs="?", help="path to session .jsonl")
    p.add_argument("--out", help="write audit here (default: stdout)")
    p.add_argument("--cwd", default=os.getcwd(), help="cwd to resolve session for")
    p.add_argument("--full", action="store_true", help="do not truncate")
    args = p.parse_args(argv)

    path = args.transcript or find_latest_transcript(args.cwd)
    if not path or not os.path.isfile(path):
        sys.stderr.write(
            "No transcript found. Pass one explicitly or run from a project cwd.\n"
        )
        return 1
    args._transcript = path
    rows = load(path)
    audit = render(rows, args)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(audit)
        sys.stderr.write(f"Audit written: {args.out} ({len(audit)} bytes)\n")
    else:
        sys.stdout.write(audit)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

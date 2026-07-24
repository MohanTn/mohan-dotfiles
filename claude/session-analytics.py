#!/usr/bin/env python3
"""session-analytics.py — a curses TUI that mines Claude Code session transcripts
for workflow analytics and lets you jot observation notes to review later.

It complements session-audit.py: where that renders ONE session into a readable
trace, this reads ALL sessions across every harness — Claude
(~/.claude/projects), Copilot (~/.copilot/session-state), and pi
(~/.pi/agent/sessions) — normalizing each schema into one comparable record:
turns, tool mix, token/cache efficiency, hook fires, tool errors, and
GOAL_CHECK outcomes, so recurring workflow patterns surface. Copilot logs carry
no token usage, so token metrics read zero for copilot sessions.

Views (keys shown in the footer):
  list       scrollable session table; sort (s), search (/), open (Enter)
  detail     one session's full metrics + tool-mix bars + its notes; add note (n)
  dashboard  aggregate analytics across the currently-filtered sessions (d)
  notes      every observation note you've saved, newest first (N)

Notes persist to ~/.claude/session-notes.jsonl (one JSON object per line) so they
survive across runs and can be grepped independently of the TUI.

Color themes (ocean, dracula, matrix, gruvbox, rose, mono) render on the
terminal's own background via use_default_colors(); cycle with 't' in-app (the
choice is remembered in ~/.claude/session-analytics.json) or pick with --theme.

Usage:
  session-analytics.py            # launch the TUI over every project
  session-analytics.py --cwd DIR  # only sessions recorded for DIR's project
  session-analytics.py --report   # print the aggregate dashboard as text (no TUI)
  session-analytics.py --limit N  # only scan the N most-recent transcripts
  session-analytics.py --harness H # only claude | copilot | pi sessions
  session-analytics.py --theme T  # start in theme T (default: last used)
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
# Transcript roots per harness — all three drop JSONL event logs, each in its
# own schema; parsers below normalize them into the shared Session record.
HARNESS_ROOTS = {
    "claude": PROJECTS,
    "copilot": os.path.join(HOME, ".copilot", "session-state"),
    "pi": os.path.join(HOME, ".pi", "agent", "sessions"),
}
HARNESS_SHORT = {"claude": "cla", "copilot": "cop", "pi": "pi"}
NOTES_PATH = os.path.join(HOME, ".claude", "session-notes.jsonl")
_MIN_TS = datetime(1900, 1, 1, tzinfo=timezone.utc)


# ---- parsing -----------------------------------------------------------------

def slugify_cwd(cwd: str) -> str:
    return "".join(c if c.isalnum() else "-" for c in cwd)


def _parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None


@dataclass
class Session:
    session_id: str = ""
    path: str = ""
    harness: str = "claude"      # claude | copilot | pi — which agent recorded it
    project: str = ""            # true cwd when recorded, else de-slugged dir name
    title: str = ""              # ai-title when present
    start: "datetime | None" = None
    end: "datetime | None" = None
    user_turns: int = 0          # real user prompts (slash/local noise excluded)
    assistant_msgs: int = 0
    tools: Counter = field(default_factory=Counter)
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read: int = 0
    cache_creation: int = 0
    hook_fires: Counter = field(default_factory=Counter)
    hook_errors: int = 0         # hook_success rows with a non-zero exit code
    tool_errors: int = 0         # errored tool_result rows (incl. exit-2 hook blocks)
    errors: list = field(default_factory=list)  # [{tool, cmd, msg, sig}] per failure
    prompts: list = field(default_factory=list)  # full text of each real user prompt
    files_written: set = field(default_factory=set)   # Write targets (created)
    files_edited_raw: set = field(default_factory=set)  # Edit/MultiEdit targets
    files_removed: set = field(default_factory=set)   # paths from Bash `rm`
    models: set = field(default_factory=set)
    goal: str = ""               # 'achieved' | 'not_achieved' | '' (no GOAL_CHECK)

    @property
    def total_tools(self) -> int:
        return sum(self.tools.values())

    @property
    def duration_min(self) -> float:
        if self.start and self.end:
            return max(0.0, (self.end - self.start).total_seconds() / 60.0)
        return 0.0

    @property
    def total_tokens(self) -> int:
        return (
            self.input_tokens
            + self.output_tokens
            + self.cache_read
            + self.cache_creation
        )

    @property
    def cache_ratio(self) -> float:
        # share of prompt-side tokens served from cache rather than fresh input.
        denom = self.cache_read + self.input_tokens + self.cache_creation
        return self.cache_read / denom if denom else 0.0

    @property
    def tokens_per_turn(self) -> float:
        return self.total_tokens / self.user_turns if self.user_turns else 0.0

    @property
    def date(self) -> str:
        d = self.start or self.end
        return d.strftime("%Y-%m-%d %H:%M") if d else ""

    @property
    def day(self) -> str:
        d = self.start or self.end
        return d.strftime("%Y-%m-%d") if d else ""

    @property
    def project_short(self) -> str:
        return os.path.basename(self.project.rstrip("/")) or self.project

    @property
    def harness_short(self) -> str:
        return HARNESS_SHORT.get(self.harness, self.harness[:3])

    # File churn as disjoint buckets: a file created this session counts as
    # "added" even if later edited; "edited" is only files not created here.
    @property
    def files_added(self) -> set:
        return self.files_written

    @property
    def files_edited(self) -> set:
        return self.files_edited_raw - self.files_written

    @property
    def n_added(self) -> int:
        return len(self.files_added)

    @property
    def n_edited(self) -> int:
        return len(self.files_edited)

    @property
    def n_removed(self) -> int:
        return len(self.files_removed)


def _iter_rows(path):
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _input_preview(name, inp, limit=120):
    """Pull the most telling field from a tool_use input so an error is
    actionable: the command for Bash, the target path for file tools, else a
    compact json dump."""
    if isinstance(inp, dict):
        for key in ("command", "file_path", "path", "pattern", "query", "url"):
            if inp.get(key):
                return str(inp[key])[:limit]
        return json.dumps(inp, ensure_ascii=False)[:limit]
    return str(inp)[:limit]


def _rm_targets(command):
    """Best-effort: pull the file/dir paths a Bash command deletes, so removals
    can be counted. Splits on shell separators, then collects the non-flag args
    of each `rm` segment."""
    targets = []
    for seg in re.split(r"[;&|]+|\n", command or ""):
        seg = seg.strip()
        m = re.match(r"(?:sudo\s+)?rm\b(.*)", seg)
        if not m:
            continue
        for tok in m.group(1).split():
            if tok.startswith("-") or tok in ("&&", "||"):
                continue
            targets.append(tok.strip("'\""))
    return targets


def _error_signature(tool, msg):
    """Collapse the volatile parts of an error message (paths, numbers, quoted
    values) so repeated deterministic failures group under one signature — the
    ones worth turning into a script or guard."""
    m = (msg or "").strip().splitlines()[0] if msg else ""
    m = re.sub(r"'[^']*'", "'…'", m)
    m = re.sub(r'"[^"]*"', '"…"', m)
    m = re.sub(r"/\S+", "/…", m)
    m = re.sub(r"\b\d+\b", "N", m)
    return f"{tool}: {m[:80]}".strip()


def parse_session(rows, path="", fallback_project="") -> Session:
    """Fold an ordered list/iterable of transcript rows into one Session record.
    Kept free of I/O so it is unit-testable with synthetic rows."""
    s = Session(path=path, project=fallback_project)
    s.session_id = (
        os.path.splitext(os.path.basename(path))[0] if path else ""
    )
    tool_by_id = {}  # tool_use_id -> (name, input), to attribute each error
    for r in rows:
        t = r.get("type")
        ts = _parse_ts(r.get("timestamp"))
        if ts:
            if s.start is None or ts < s.start:
                s.start = ts
            if s.end is None or ts > s.end:
                s.end = ts
        # true project path: several row kinds carry the recorded cwd.
        cwd = r.get("cwd")
        if cwd and not s.project:
            s.project = cwd
        if not s.session_id and r.get("sessionId"):
            s.session_id = r.get("sessionId")

        if t == "ai-title":
            s.title = r.get("aiTitle", s.title) or s.title
            continue

        if t == "attachment":
            att = r.get("attachment", {}) or {}
            if att.get("type") == "hook_success":
                key = f"{att.get('hookEvent', '?')}/{att.get('hookName', '?')}"
                s.hook_fires[key] += 1
                if att.get("exitCode", 0) not in (0, None):
                    s.hook_errors += 1
            continue

        if t == "user":
            content = r.get("message", {}).get("content")
            if isinstance(content, str):
                st = content.strip()
                if st.startswith("<local-command") or st.startswith(
                    "<command-name>"
                ):
                    continue  # slash-command / local scaffolding, not a real turn
                s.user_turns += 1
                s.prompts.append(st)
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        if c.get("is_error"):
                            s.tool_errors += 1
                            body = c.get("content", "")
                            if isinstance(body, list):
                                body = "\n".join(
                                    b.get("text", "")
                                    for b in body if isinstance(b, dict)
                                )
                            msg = str(body).strip()
                            name, inp = tool_by_id.get(
                                c.get("tool_use_id"), ("?", {})
                            )
                            s.errors.append({
                                "tool": name,
                                "cmd": _input_preview(name, inp),
                                "msg": msg[:300],
                                "sig": _error_signature(name, msg),
                            })
            continue

        if t == "assistant":
            msg = r.get("message", {})
            if msg.get("model"):
                s.models.add(msg["model"])
            usage = msg.get("usage") or {}
            s.input_tokens += usage.get("input_tokens", 0) or 0
            s.output_tokens += usage.get("output_tokens", 0) or 0
            s.cache_read += usage.get("cache_read_input_tokens", 0) or 0
            s.cache_creation += usage.get("cache_creation_input_tokens", 0) or 0
            has_text = False
            for c in msg.get("content", []) or []:
                if not isinstance(c, dict):
                    continue
                ct = c.get("type")
                if ct == "tool_use":
                    name = c.get("name", "?")
                    s.tools[name] += 1
                    if c.get("id"):
                        tool_by_id[c["id"]] = (name, c.get("input"))
                    inp = c.get("input") or {}
                    if isinstance(inp, dict):
                        fp = inp.get("file_path")
                        if name == "Write" and fp:
                            s.files_written.add(fp)
                        elif name in ("Edit", "MultiEdit", "NotebookEdit") and fp:
                            s.files_edited_raw.add(fp)
                        elif name == "Bash" and inp.get("command"):
                            s.files_removed.update(_rm_targets(inp["command"]))
                elif ct == "text":
                    has_text = True
                    txt = c.get("text", "") or ""
                    if "GOAL_CHECK:" in txt:
                        # last write wins; NOT_ACHIEVED marker checked first.
                        up = txt.upper()
                        if "NOT_ACHIEVED" in up or "NOT ACHIEVED" in up:
                            s.goal = "not_achieved"
                        elif "ACHIEVED" in up:
                            s.goal = "achieved"
            if has_text or msg.get("content"):
                s.assistant_msgs += 1
            continue

    if not s.project:
        s.project = fallback_project or "?"
    return s


def _project_from_dir(dirname: str) -> str:
    """Best-effort de-slug of a project dir name for display when no row carried
    a cwd. Ambiguous (dashes vs separators) so only a fallback."""
    return "/" + dirname.strip("-").replace("-", "/") if dirname else "?"


def _goal_from_text(s, txt):
    """Update s.goal from a GOAL_CHECK marker in assistant text; last write wins,
    NOT_ACHIEVED taking priority within one message."""
    if not txt or "GOAL_CHECK:" not in txt:
        return
    up = txt.upper()
    if "NOT_ACHIEVED" in up or "NOT ACHIEVED" in up:
        s.goal = "not_achieved"
    elif "ACHIEVED" in up:
        s.goal = "achieved"


def _agent_file_op(s, name, args):
    """Attribute a copilot/pi tool call to file churn buckets by its name+args,
    mirroring how the Claude parser tracks Write/Edit/Bash-rm."""
    if not isinstance(args, dict):
        return
    n = (name or "").lower()
    path = args.get("path") or args.get("file_path")
    if n in ("write", "create", "new_file") and path:
        s.files_written.add(path)
    elif n in ("edit", "str_replace", "multiedit", "apply_patch") and path:
        s.files_edited_raw.add(path)
    elif n in ("bash", "shell", "run", "execute") and args.get("command"):
        s.files_removed.update(_rm_targets(args["command"]))


def _pi_text(content):
    """Join the text spans of a pi message's content array (ignores thinking)."""
    if isinstance(content, str):
        return content
    return "\n".join(
        c.get("text", "") or ""
        for c in (content or [])
        if isinstance(c, dict) and c.get("type") == "text"
    )


def parse_copilot_session(rows, path="", fallback_project="") -> Session:
    """Fold a copilot events.jsonl (schema: type=session.start/user.message/
    assistant.message/tool.execution_complete/hook.*) into a Session. Copilot
    records no token usage, so token metrics stay zero for these."""
    s = Session(path=path, harness="copilot")
    tool_by_id = {}  # toolCallId -> (name, arguments)
    for r in rows:
        ts = _parse_ts(r.get("timestamp"))
        if ts:
            if s.start is None or ts < s.start:
                s.start = ts
            if s.end is None or ts > s.end:
                s.end = ts
        t = r.get("type")
        d = r.get("data") or {}
        if t == "session.start":
            s.session_id = d.get("sessionId", s.session_id) or s.session_id
            ctx = d.get("context") or {}
            if ctx.get("cwd"):
                s.project = ctx["cwd"]
            st = _parse_ts(d.get("startTime"))
            if st and (s.start is None or st < s.start):
                s.start = st
        elif t in ("session.model_change", "session.auto_mode_resolved"):
            m = d.get("newModel") or d.get("chosenModel")
            if m:
                s.models.add(m)
        elif t == "user.message":
            c = d.get("content")
            if isinstance(c, str) and c.strip():
                s.user_turns += 1
                s.prompts.append(c.strip())
        elif t == "assistant.message":
            if d.get("model"):
                s.models.add(d["model"])
            txt = d.get("content") or ""
            _goal_from_text(s, txt if isinstance(txt, str) else "")
            if txt or d.get("toolRequests"):
                s.assistant_msgs += 1
            for tr in d.get("toolRequests") or []:
                name = tr.get("name", "?")
                s.tools[name] += 1
                if tr.get("toolCallId"):
                    tool_by_id[tr["toolCallId"]] = (name, tr.get("arguments"))
                _agent_file_op(s, name, tr.get("arguments"))
        elif t == "tool.execution_complete":
            if d.get("success") is False:
                s.tool_errors += 1
                name, args = tool_by_id.get(
                    d.get("toolCallId"), (d.get("toolName", "?"), {})
                )
                msg = (d.get("error") or {}).get("message") or "tool failed"
                s.errors.append({
                    "tool": name,
                    "cmd": _input_preview(name, args),
                    "msg": str(msg)[:300],
                    "sig": _error_signature(name, msg),
                })
        elif t == "hook.end":
            s.hook_fires[d.get("hookType", "?")] += 1
            ec = d.get("exitCode")
            if ec not in (0, None):
                s.hook_errors += 1
    if not s.project:
        s.project = fallback_project or "?"
    return s


def parse_pi_session(rows, path="", fallback_project="") -> Session:
    """Fold a pi session jsonl (schema: type=session/model_change/message with
    message.role in user/assistant/toolResult) into a Session. Pi records full
    token usage per message, so all token metrics are available."""
    s = Session(path=path, harness="pi")
    for r in rows:
        ts = _parse_ts(r.get("timestamp"))
        if ts:
            if s.start is None or ts < s.start:
                s.start = ts
            if s.end is None or ts > s.end:
                s.end = ts
        t = r.get("type")
        if t == "session":
            s.session_id = r.get("id", s.session_id) or s.session_id
            if r.get("cwd"):
                s.project = r["cwd"]
        elif t == "model_change":
            if r.get("modelId"):
                s.models.add(r["modelId"])
        elif t == "message":
            m = r.get("message") or {}
            role = m.get("role")
            u = m.get("usage") or {}
            if u:
                s.input_tokens += u.get("input", 0) or 0
                s.output_tokens += u.get("output", 0) or 0
                s.cache_read += u.get("cacheRead", 0) or 0
                s.cache_creation += u.get("cacheWrite", 0) or 0
            content = m.get("content") or []
            if role == "user":
                txt = _pi_text(content)
                if txt.strip():
                    s.user_turns += 1
                    s.prompts.append(txt.strip())
            elif role == "assistant":
                s.assistant_msgs += 1
                _goal_from_text(s, _pi_text(content))
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "toolCall":
                        name = c.get("name", "?")
                        s.tools[name] += 1
                        _agent_file_op(s, name, c.get("arguments"))
            elif role == "toolResult":
                if m.get("isError"):
                    s.tool_errors += 1
                    name = m.get("toolName", "?")
                    body = _pi_text(m.get("content") or [])
                    s.errors.append({
                        "tool": name,
                        "cmd": name,
                        "msg": body[:300],
                        "sig": _error_signature(name, body),
                    })
    if not s.project:
        s.project = fallback_project or "?"
    return s


PARSERS = {
    "claude": parse_session,
    "copilot": parse_copilot_session,
    "pi": parse_pi_session,
}


def _harness_files(cwd=None, harness=None):
    """(harness, path) for every transcript across the selected harness(es),
    newest first. Claude is dir-scoped by cwd (slug); copilot/pi have no
    per-project dirs, so they're scanned whole and cwd-filtered post-parse."""
    files = []
    want = lambda h: harness is None or harness == h
    if want("claude"):
        root = HARNESS_ROOTS["claude"]
        if cwd:
            dirs = [os.path.join(root, slugify_cwd(os.path.abspath(cwd)))]
        elif os.path.isdir(root):
            dirs = [os.path.join(root, d) for d in os.listdir(root)
                    if os.path.isdir(os.path.join(root, d))]
        else:
            dirs = []
        for d in dirs:
            if os.path.isdir(d):
                files += [("claude", f)
                          for f in glob.glob(os.path.join(d, "*.jsonl"))]
    if want("copilot"):
        root = HARNESS_ROOTS["copilot"]
        if os.path.isdir(root):
            files += [("copilot", f)
                      for f in glob.glob(os.path.join(root, "*", "events.jsonl"))]
    if want("pi"):
        root = HARNESS_ROOTS["pi"]
        if os.path.isdir(root):
            files += [("pi", f) for f in
                      glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)]
    files.sort(key=lambda hf: os.path.getmtime(hf[1]), reverse=True)
    return files


def load_sessions(cwd=None, limit=None, harness=None):
    """Scan transcripts across all harnesses (claude/copilot/pi) and return
    parsed Sessions, newest first. `harness` limits to one; `cwd` scopes to a
    project; `limit` caps the number of most-recent transcripts scanned."""
    files = _harness_files(cwd=cwd, harness=harness)
    if limit:
        files = files[:limit]

    sessions = []
    for h, f in files:
        dirname = os.path.basename(os.path.dirname(f))
        try:
            s = PARSERS[h](
                _iter_rows(f), path=f, fallback_project=_project_from_dir(dirname)
            )
        except Exception:
            continue
        s.harness = h
        if s.user_turns == 0 and s.total_tools == 0 and not s.title:
            continue  # empty / aborted transcript, nothing to analyze
        # claude is already dir-scoped by cwd; filter copilot/pi by recorded cwd.
        if cwd and h != "claude":
            if os.path.abspath(s.project or "") != os.path.abspath(cwd):
                continue
        sessions.append(s)
    return sessions


# ---- aggregation -------------------------------------------------------------

@dataclass
class Aggregate:
    n_sessions: int = 0
    turns: int = 0
    tool_calls: int = 0
    tokens: int = 0
    output_tokens: int = 0
    cache_read: int = 0
    input_and_creation: int = 0
    tool_errors: int = 0
    hook_errors: int = 0
    goal_achieved: int = 0
    goal_not: int = 0
    goal_none: int = 0
    top_tools: Counter = field(default_factory=Counter)
    hook_fires: Counter = field(default_factory=Counter)
    by_project: Counter = field(default_factory=Counter)         # sessions/project
    by_harness: Counter = field(default_factory=Counter)         # sessions/harness
    errors_by_project: Counter = field(default_factory=Counter)
    errors_by_tool: Counter = field(default_factory=Counter)     # failures per tool
    error_patterns: Counter = field(default_factory=Counter)     # signature -> count
    error_examples: dict = field(default_factory=dict)           # signature -> sample
    tokens_by_day: Counter = field(default_factory=Counter)      # YYYY-MM-DD -> tokens
    total_minutes: float = 0.0

    @property
    def cache_ratio(self) -> float:
        denom = self.cache_read + self.input_and_creation
        return self.cache_read / denom if denom else 0.0

    @property
    def output_input_ratio(self) -> float:
        # output tokens generated per token of fresh input (input + cache-create).
        return self.output_tokens / self.input_and_creation if self.input_and_creation else 0.0

    @property
    def tool_error_rate(self) -> float:
        # share of tool calls that errored.
        return self.tool_errors / self.tool_calls if self.tool_calls else 0.0

    @property
    def goal_rate(self) -> float:
        scored = self.goal_achieved + self.goal_not
        return self.goal_achieved / scored if scored else 0.0

    @property
    def avg_turns(self) -> float:
        return self.turns / self.n_sessions if self.n_sessions else 0.0


def aggregate(sessions) -> Aggregate:
    a = Aggregate(n_sessions=len(sessions))
    for s in sessions:
        a.turns += s.user_turns
        a.tool_calls += s.total_tools
        a.tokens += s.total_tokens
        a.output_tokens += s.output_tokens
        a.cache_read += s.cache_read
        a.input_and_creation += s.input_tokens + s.cache_creation
        a.tool_errors += s.tool_errors
        a.hook_errors += s.hook_errors
        a.total_minutes += s.duration_min
        a.top_tools.update(s.tools)
        a.hook_fires.update(s.hook_fires)
        a.by_project[s.project_short] += 1
        a.by_harness[s.harness] += 1
        if s.day:
            a.tokens_by_day[s.day] += s.total_tokens
        if s.tool_errors:
            a.errors_by_project[s.project_short] += s.tool_errors
        for e in s.errors:
            a.errors_by_tool[e.get("tool", "?")] += 1
            sig = e.get("sig", "?")
            a.error_patterns[sig] += 1
            a.error_examples.setdefault(sig, e)
        if s.goal == "achieved":
            a.goal_achieved += 1
        elif s.goal == "not_achieved":
            a.goal_not += 1
        else:
            a.goal_none += 1
    return a


# ---- notes -------------------------------------------------------------------

def load_notes(path=NOTES_PATH):
    notes = []
    if not os.path.isfile(path):
        return notes
    for r in _iter_rows(path):
        if isinstance(r, dict) and r.get("note"):
            notes.append(r)
    notes.sort(key=lambda n: n.get("ts", ""), reverse=True)
    return notes


def save_note(session_id, project, title, text, path=NOTES_PATH):
    rec = {
        "session_id": session_id,
        "project": project,
        "title": title,
        "note": text,
        "ts": datetime.now().isoformat(timespec="seconds"),
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return rec


def notes_for(session_id, notes):
    return [n for n in notes if n.get("session_id") == session_id]


# ---- sorting -----------------------------------------------------------------

SORT_KEYS = [
    ("date", lambda s: (s.start or _MIN_TS)),
    ("turns", lambda s: s.user_turns),
    ("tools", lambda s: s.total_tools),
    ("errors", lambda s: s.tool_errors),
    ("tokens", lambda s: s.total_tokens),
    ("duration", lambda s: s.duration_min),
]


def sort_sessions(sessions, idx):
    name, key = SORT_KEYS[idx % len(SORT_KEYS)]
    return name, sorted(sessions, key=key, reverse=True)


def _fmt_int(n):
    return f"{n:,}"


def _fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


# ---- text report (non-TUI) ---------------------------------------------------

def render_report(sessions) -> str:
    a = aggregate(sessions)
    L = []
    w = L.append
    w("Claude Code — Session Analytics")
    w("=" * 60)
    w(f"Sessions analyzed : {a.n_sessions}"
      + (f"   [{', '.join(f'{h}:{c}' for h, c in a.by_harness.most_common())}]"
         if a.by_harness else ""))
    w(f"User turns        : {_fmt_int(a.turns)}  (avg {a.avg_turns:.1f}/session)")
    w(f"Tool calls        : {_fmt_int(a.tool_calls)}")
    w(f"Tokens total      : {_fmt_tokens(a.tokens)}")
    w(f"  Input           : {_fmt_tokens(a.input_and_creation)} (input + cache-create)")
    w(f"  Output          : {_fmt_tokens(a.output_tokens)}")
    w(f"  Cache read      : {_fmt_tokens(a.cache_read)} (cache hit {a.cache_ratio*100:.0f}%)")
    w(f"  Out/In ratio    : {a.output_input_ratio:.2f} (output per fresh-input token)")
    w(f"Active time       : {a.total_minutes/60:.1f} h")
    w(f"Tool errors       : {a.tool_errors}   hook errors: {a.hook_errors}"
      f"   (err rate {a.tool_error_rate*100:.1f}% of {_fmt_int(a.tool_calls)} calls)")
    scored = a.goal_achieved + a.goal_not
    w(f"GOAL_CHECK        : {a.goal_achieved} achieved / {a.goal_not} not "
      f"({a.goal_rate*100:.0f}% of {scored} scored; {a.goal_none} unscored)")
    w("")
    w("Top tools:")
    for name, c in a.top_tools.most_common(12):
        w(f"  {name:<14} {_fmt_int(c)}")
    w("")
    w("Hook fires:")
    for name, c in a.hook_fires.most_common(12):
        w(f"  {name:<40} {_fmt_int(c)}")
    w("")
    w("Busiest projects:")
    for name, c in a.by_project.most_common(10):
        errs = a.errors_by_project.get(name, 0)
        w(f"  {name:<24} {c:>4} sessions   {errs} tool-errors")
    w("")
    w("Tokens per day (oldest→newest):")
    days = sorted(a.tokens_by_day.items())
    if not days:
        w("  (none)")
    else:
        mx = max(v for _, v in days)
        for day, toks in days:
            w(f"  {day}  {_fmt_tokens(toks):>7} {_bar(toks, mx, 30)}")
    w("")
    w("Errors by tool:")
    for name, c in a.errors_by_tool.most_common(10):
        w(f"  {name:<14} {c}")
    w("")
    w("Recurring error patterns (deterministic-script candidates):")
    if not a.error_patterns:
        w("  (none)")
    for sig, c in a.error_patterns.most_common(12):
        ex = a.error_examples.get(sig, {})
        w(f"  {c:>3}× {sig}")
        if ex.get("cmd"):
            w(f"        e.g. {ex['cmd'][:100]}")
    return "\n".join(L)


# ---- curses TUI --------------------------------------------------------------

def _bar(value, total, width):
    if total <= 0:
        return ""
    filled = int(round(width * value / total))
    return "█" * filled + "·" * (width - filled)


# Themes map semantic roles to (color-name | None, attr-flags). Flags: R=reverse,
# B=bold, U=underline, D=dim. With use_default_colors() the terminal's own
# background shows through, which fixes the washed-out "cloudy" look.
THEME_NAMES = ["ocean", "dracula", "matrix", "gruvbox", "rose", "mono"]

_THEME_SPECS = {
    "mono": {  # no color — for terminals without it, or minimalists
        "title": (None, "RB"), "sel": (None, "R"), "head": (None, "BU"),
        "dim": (None, "D"), "accent": (None, "B"), "ok": (None, "B"),
        "err": (None, "B"), "warn": (None, "D"),
    },
    "ocean": {
        "title": ("cyan", "RB"), "sel": ("cyan", "R"), "head": ("cyan", "BU"),
        "dim": (None, "D"), "accent": ("blue", "B"), "ok": ("green", "B"),
        "err": ("red", "B"), "warn": ("yellow", "B"),
    },
    "dracula": {
        "title": ("magenta", "RB"), "sel": ("magenta", "R"),
        "head": ("magenta", "BU"), "dim": (None, "D"), "accent": ("cyan", "B"),
        "ok": ("green", "B"), "err": ("red", "B"), "warn": ("yellow", "B"),
    },
    "matrix": {
        "title": ("green", "RB"), "sel": ("green", "R"), "head": ("green", "BU"),
        "dim": ("green", "D"), "accent": ("green", "B"), "ok": ("green", "B"),
        "err": ("red", "B"), "warn": ("yellow", "B"),
    },
    "gruvbox": {
        "title": ("yellow", "RB"), "sel": ("yellow", "R"),
        "head": ("yellow", "BU"), "dim": (None, "D"), "accent": ("green", "B"),
        "ok": ("green", "B"), "err": ("red", "B"), "warn": ("yellow", "B"),
    },
    "rose": {
        "title": ("magenta", "RB"), "sel": ("red", "R"), "head": ("magenta", "BU"),
        "dim": (None, "D"), "accent": ("red", "B"), "ok": ("green", "B"),
        "err": ("red", "B"), "warn": ("yellow", "B"),
    },
}

CONFIG_PATH = os.path.join(HOME, ".claude", "session-analytics.json")


def load_config(path=CONFIG_PATH):
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh) or {}
        except Exception:
            return {}
    return {}


def save_config(cfg, path=CONFIG_PATH):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)
    except Exception:
        pass


class Theme:
    """Resolves a named theme's roles into ready-to-use curses attributes,
    allocating one color pair per colored role."""

    def __init__(self, name):
        self.name = name if name in _THEME_SPECS else THEME_NAMES[0]
        self._attrs = {}

    def init(self, curses):
        self._attrs = {}
        color_ok = False
        try:
            if curses.has_colors():
                curses.start_color()
                curses.use_default_colors()  # keep terminal's real background
                color_ok = True
        except Exception:
            color_ok = False
        cmap = {}
        if color_ok:
            for n in ("black", "red", "green", "yellow",
                      "blue", "magenta", "cyan", "white"):
                cmap[n] = getattr(curses, "COLOR_" + n.upper())
        pid = 1
        for role, (color, flags) in _THEME_SPECS[self.name].items():
            a = 0
            if "R" in flags:
                a |= curses.A_REVERSE
            if "B" in flags:
                a |= curses.A_BOLD
            if "U" in flags:
                a |= curses.A_UNDERLINE
            if "D" in flags:
                a |= curses.A_DIM
            if color and color_ok:
                try:
                    curses.init_pair(pid, cmap[color], -1)
                    a |= curses.color_pair(pid)
                    pid += 1
                except Exception:
                    pass
            self._attrs[role] = a

    def a(self, role):
        return self._attrs.get(role, 0)


class App:
    def __init__(self, stdscr, sessions, theme=None):
        self.scr = stdscr
        self.all_sessions = sessions
        self.sort_idx = 0
        self.filter = ""
        self.notes = load_notes()
        # picker | list | detail | dashboard | errors | timeline | notes
        self.view = "picker"         # open on the agent picker
        self.harness_sel = None      # None = all agents; else claude|copilot|pi
        self.picker_opts = [
            ("all", "All agents"),
            ("claude", "Claude Code"),
            ("copilot", "Copilot"),
            ("pi", "Pi agent"),
        ]
        self.cursor = 0
        self.scroll = 0
        self.dscroll = 0             # vertical scroll within the detail view
        self.detail = None           # Session being viewed
        self.status = ""
        name = theme or load_config().get("theme") or THEME_NAMES[0]
        self.theme = Theme(name)
        self._apply()

    def _a(self, role):
        return self.theme.a(role)

    def _cycle_theme(self):
        import curses
        i = (THEME_NAMES.index(self.theme.name) + 1) % len(THEME_NAMES)
        self.theme = Theme(THEME_NAMES[i])
        self.theme.init(curses)
        save_config({**load_config(), "theme": self.theme.name})
        self.status = f"theme: {self.theme.name}"

    # -- data shaping --
    def _apply(self):
        base = self.all_sessions
        if self.harness_sel:
            base = [s for s in base if s.harness == self.harness_sel]
        if self.filter:
            f = self.filter.lower()
            base = [
                s for s in base
                if f in s.project_short.lower() or f in s.title.lower()
                or f in s.harness.lower()
            ]
        self.sort_name, self.sessions = sort_sessions(base, self.sort_idx)
        self.cursor = min(self.cursor, max(0, len(self.sessions) - 1))

    # -- generic input prompt at the footer --
    def _prompt(self, label):
        import curses
        h, w = self.scr.getmaxyx()
        curses.curs_set(1)
        curses.echo()
        self.scr.move(h - 1, 0)
        self.scr.clrtoeol()
        self.scr.addstr(h - 1, 0, label[: w - 1], self._a("sel"))
        self.scr.refresh()
        buf = ""
        while True:
            try:
                ch = self.scr.get_wch()
            except Exception:
                break
            if ch in ("\n", "\r"):
                break
            if ch in ("\x1b",):  # esc cancels
                buf = None
                break
            if ch in ("\x7f", "\b", curses.KEY_BACKSPACE, 127, 8):
                buf = buf[:-1]
            elif isinstance(ch, str) and ch.isprintable():
                buf += ch
            self.scr.move(h - 1, 0)
            self.scr.clrtoeol()
            self.scr.addstr(
                h - 1, 0, (label + buf)[: w - 1], self._a("sel")
            )
            self.scr.refresh()
        curses.noecho()
        curses.curs_set(0)
        return buf

    # -- rendering helpers --
    def _addstr(self, y, x, text, attr=0):
        h, w = self.scr.getmaxyx()
        if 0 <= y < h and x < w:
            try:
                self.scr.addstr(y, x, text[: w - 1 - x], attr)
            except Exception:
                pass

    def _footer(self, keys):
        import curses
        h, w = self.scr.getmaxyx()
        bar = "  ".join(keys)
        self._addstr(h - 1, 0, bar.ljust(w - 1), self._a("sel"))
        if self.status:
            self._addstr(h - 2, 0, self.status[: w - 1], self._a("dim"))

    # -- picker view (opening screen: choose an agent to drill into) --
    def _picker_cursor_for_sel(self):
        key = self.harness_sel or "all"
        for i, (k, _) in enumerate(self.picker_opts):
            if k == key:
                return i
        return 0

    def _draw_picker(self):
        from collections import Counter
        h, w = self.scr.getmaxyx()
        self._addstr(0, 0, " Session Analytics — choose an agent ".ljust(w - 1),
                     self._a("title"))
        self._addstr(2, 4, "Pick an agent to scope every view "
                     "(list, dashboard, timeline, errors) to it.", self._a("dim"))
        counts = Counter(s.harness for s in self.all_sessions)
        total = len(self.all_sessions)
        y = 4
        for i, (key, label) in enumerate(self.picker_opts):
            n = total if key == "all" else counts.get(key, 0)
            marker = "▶ " if i == self.cursor else "  "
            attr = self._a("sel") if i == self.cursor else self._a("accent")
            self._addstr(y, 4, f"{marker}{label:<16}{n:>5} sessions", attr)
            y += 2
        self._footer(["↑↓/jk move", "Enter select",
                      f"t theme:{self.theme.name}", "q quit"])

    # -- list view --
    def _draw_list(self):
        import curses
        h, w = self.scr.getmaxyx()
        agent = dict(self.picker_opts).get(self.harness_sel or "all", "All agents")
        title = (
            f" {agent} — {len(self.sessions)} sessions "
            f"| sort:{self.sort_name}"
            + (f" | filter:'{self.filter}'" if self.filter else "")
        )
        self._addstr(0, 0, title.ljust(w - 1), self._a("title"))
        hdr = f"{'DATE':<16} {'AGT':<3} {'PROJECT':<14} {'TURN':>3} {'TOOL':>3} {'ERR':>2} {'IN':>5} {'OUT':>5} {'CACHE':>5} {'GOAL':<4} TITLE"
        self._addstr(1, 0, hdr, self._a("head"))

        rows = h - 4  # header(2) + footer(2)
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        elif self.cursor >= self.scroll + rows:
            self.scroll = self.cursor - rows + 1

        for i in range(rows):
            si = self.scroll + i
            if si >= len(self.sessions):
                break
            s = self.sessions[si]
            g = {"achieved": "✓", "not_achieved": "✗", "": "·"}[s.goal]
            cache_total = s.cache_read + s.cache_creation
            line = (
                f"{s.date:<16} {s.harness_short:<3} {s.project_short[:14]:<14} "
                f"{s.user_turns:>3} {s.total_tools:>3} {s.tool_errors:>2} "
                f"{_fmt_tokens(s.input_tokens):>5} {_fmt_tokens(s.output_tokens):>5} "
                f"{_fmt_tokens(cache_total):>5} {g:<4} {s.title[:50]}"
            )
            attr = self._a("sel") if si == self.cursor else 0
            if s.tool_errors and si != self.cursor:
                attr |= self._a("dim")
            self._addstr(2 + i, 0, line, attr)

        self._footer([
            "↑↓/jk move", "Enter open", "a agents", "s sort", "/ search",
            "d dashboard", "e errors", "v timeline", "N notes",
            f"t theme:{self.theme.name}", "q back",
        ])

    # -- detail view (scrollable line buffer) --
    def _detail_lines(self, s, w):
        import curses
        B = self._a("head")
        D = self._a("dim")
        L = []  # (indent, text, attr)

        def add(indent, text, attr=0):
            L.append((indent, text, attr))

        for line in [
            f"Harness    : {s.harness}",
            f"Project    : {s.project}",
            f"Session    : {s.session_id}",
            f"When       : {s.date}   ({s.duration_min:.0f} min)",
            f"Model      : {', '.join(sorted(s.models)) or '?'}",
            f"Turns      : {s.user_turns}    Assistant msgs: {s.assistant_msgs}",
            f"Tool calls : {s.total_tools}    Tool errors: {s.tool_errors}",
            f"Files      : +{s.n_added} added   ~{s.n_edited} edited   "
            f"-{s.n_removed} removed",
            f"Tokens total   : {_fmt_int(s.total_tokens)}  "
            f"({_fmt_int(int(s.tokens_per_turn))}/turn)",
            f"  Input        : {_fmt_int(s.input_tokens)}",
            f"  Output       : {_fmt_int(s.output_tokens)}",
            f"  Cache read   : {_fmt_int(s.cache_read)}  "
            f"(cache-hit {s.cache_ratio*100:.0f}%)",
            f"  Cache create : {_fmt_int(s.cache_creation)}",
            f"Hook fires : {sum(s.hook_fires.values())}  (errors {s.hook_errors})",
            f"GOAL_CHECK : {s.goal or 'not recorded'}",
        ]:
            add(2, line)

        add(0, "", 0)
        add(2, f"User prompts ({len(s.prompts)})", B)
        if not s.prompts:
            add(4, "(none captured)", D)
        for i, p in enumerate(s.prompts, 1):
            first = True
            for wl in _wrap(p, w - 8):
                add(4, (f"{i}. " if first else "   ") + wl)
                first = False

        add(0, "", 0)
        add(2, "Tool mix", B)
        top = s.tools.most_common(12)
        mx = max((c for _, c in top), default=1)
        for name, c in top:
            add(4, f"{name:<14} {c:>4} {_bar(c, mx, 24)}")

        if s.files_added or s.files_edited or s.files_removed:
            add(0, "", 0)
            add(2, "Files changed", B)
            for fp in sorted(s.files_added):
                add(4, f"+ {fp}")
            for fp in sorted(s.files_edited):
                add(4, f"~ {fp}")
            for fp in sorted(s.files_removed):
                add(4, f"- {fp}")

        if s.hook_fires:
            add(0, "", 0)
            add(2, "Hook fires", B)
            for name, c in s.hook_fires.most_common(8):
                add(4, f"{name:<42} {c}")

        if s.errors:
            add(0, "", 0)
            add(2, f"Tool errors ({len(s.errors)})", B)
            for e in s.errors:
                add(4, f"✗ {e['tool']}: {e['cmd']}", self._a("err"))
                add(6, e["msg"].splitlines()[0] if e["msg"] else "(no message)", D)

        add(0, "", 0)
        add(2, "Notes", B)
        mine = notes_for(s.session_id, self.notes)
        if not mine:
            add(4, "(none yet — press n to add an observation)", D)
        for n in mine:
            add(4, f"• [{n.get('ts', '')[:16]}] {n.get('note', '')}")
        return L

    def _draw_detail(self):
        import curses
        s = self.detail
        h, w = self.scr.getmaxyx()
        lines = self._detail_lines(s, w)
        body_rows = h - 3  # title(1) + footer(2)
        maxscroll = max(0, len(lines) - body_rows)
        self.dscroll = max(0, min(self.dscroll, maxscroll))

        pct = f"  [{self.dscroll}/{maxscroll}]" if maxscroll else ""
        self._addstr(0, 0, f" {s.title or s.session_id}{pct} ".ljust(w - 1),
                     self._a("title"))
        for i in range(body_rows):
            li = self.dscroll + i
            if li >= len(lines):
                break
            indent, text, attr = lines[li]
            self._addstr(1 + i, indent, text, attr)

        self._footer(["↑↓/jk scroll", "PgUp/PgDn", "n add note",
                      "b/Esc back", "q quit"])

    # -- dashboard view --
    def _draw_dashboard(self):
        import curses
        a = aggregate(self.sessions)
        h, w = self.scr.getmaxyx()
        scope = f"'{self.filter}'" if self.filter else "all projects"
        hbits = ", ".join(f"{h}:{c}" for h, c in a.by_harness.most_common())
        self._addstr(0, 0, f" Dashboard — {scope} ({a.n_sessions} sessions) "
                     .ljust(w - 1), self._a("title"))
        y = 2
        scored = a.goal_achieved + a.goal_not
        lines = [
            f"Harnesses     : {hbits or '(none)'}",
            f"User turns    : {_fmt_int(a.turns)}   (avg {a.avg_turns:.1f}/session)",
            f"Tool calls    : {_fmt_int(a.tool_calls)}",
            f"Tokens total  : {_fmt_tokens(a.tokens)}",
            f"  Input       : {_fmt_tokens(a.input_and_creation)} (input + cache-create)",
            f"  Output      : {_fmt_tokens(a.output_tokens)}",
            f"  Cache read  : {_fmt_tokens(a.cache_read)}  (cache-hit {a.cache_ratio*100:.0f}%)",
            f"  Out/In ratio: {a.output_input_ratio:.2f}  (output per fresh-input token)",
            f"Active time   : {a.total_minutes/60:.1f} h",
            f"Tool errors   : {a.tool_errors}    Hook errors: {a.hook_errors}"
            f"   (err rate {a.tool_error_rate*100:.1f}% of {_fmt_int(a.tool_calls)} calls)",
            f"GOAL_CHECK    : {a.goal_achieved}✓ / {a.goal_not}✗  "
            f"({a.goal_rate*100:.0f}% of {scored} scored, {a.goal_none} unscored)",
        ]
        for line in lines:
            self._addstr(y, 2, line)
            y += 1
        y += 1

        col2 = max(38, w // 2)
        self._addstr(y, 2, "Top tools", self._a("head"))
        self._addstr(y, col2, "Busiest projects",
                     self._a("head"))
        y += 1
        tools = a.top_tools.most_common(10)
        projs = a.by_project.most_common(10)
        mxt = max((c for _, c in tools), default=1)
        for i in range(max(len(tools), len(projs))):
            if i < len(tools):
                name, c = tools[i]
                self._addstr(y, 4, f"{name:<12}{c:>5} {_bar(c, mxt, 14)}")
            if i < len(projs):
                name, c = projs[i]
                errs = a.errors_by_project.get(name, 0)
                etag = f"  {errs}err" if errs else ""
                self._addstr(y, col2 + 2, f"{name[:20]:<20}{c:>4}{etag}")
            y += 1

        if a.error_patterns:
            y += 1
            self._addstr(
                y, 2,
                "Recurring error patterns (deterministic-script candidates)",
                self._a("head"))
            y += 1
            for sig, c in a.error_patterns.most_common(8):
                ex = a.error_examples.get(sig, {})
                self._addstr(y, 4, f"{c:>3}× {sig[:w-12]}", self._a("accent"))
                y += 1
                cmd = ex.get("cmd", "")
                if cmd:
                    self._addstr(y, 8, f"e.g. {cmd[:w-14]}", self._a("dim"))
                    y += 1

        self._footer(["e errors", "v timeline", "b/Esc back", "N notes", "q quit"])

    # -- errors view --
    def _draw_errors(self):
        import curses
        a = aggregate(self.sessions)
        h, w = self.scr.getmaxyx()
        patterns = a.error_patterns.most_common()
        scope = f"'{self.filter}'" if self.filter else "all projects"
        self._addstr(
            0, 0,
            f" Error patterns — {scope} ({len(patterns)} distinct, "
            f"{a.tool_errors} total) ".ljust(w - 1),
            self._a("title"))
        self._addstr(1, 0, "Grouped by normalized signature; most frequent first "
                     "→ best deterministic-script candidates.", self._a("dim"))

        rows = h - 4
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        elif self.cursor >= self.scroll + max(1, rows // 3):
            self.scroll = self.cursor - max(1, rows // 3) + 1

        y = 2
        for i, (sig, c) in enumerate(patterns[self.scroll:], start=self.scroll):
            if y >= h - 2:
                break
            ex = a.error_examples.get(sig, {})
            attr = self._a("sel") if i == self.cursor else self._a("err")
            self._addstr(y, 0, f"{c:>3}× {sig}"[:w - 1], attr)
            y += 1
            if ex.get("cmd"):
                self._addstr(y, 5, f"input: {ex['cmd'][:w - 13]}", self._a("dim"))
                y += 1
            if ex.get("msg"):
                self._addstr(y, 5, f"error: {ex['msg'].splitlines()[0][:w - 13]}",
                             self._a("dim"))
                y += 1
        if not patterns:
            self._addstr(3, 4, "No tool errors in scope. 🎉", self._a("dim"))
        self._footer(["↑↓ move", "b/Esc back", "q quit"])

    # -- timeline view (tokens per day, oldest→newest) --
    def _draw_timeline(self):
        import curses
        a = aggregate(self.sessions)
        h, w = self.scr.getmaxyx()
        days = sorted(a.tokens_by_day.items())  # ascending by date
        scope = f"'{self.filter}'" if self.filter else "all projects"
        self._addstr(0, 0, f" Token timeline — {scope} ({len(days)} days) "
                     .ljust(w - 1), self._a("title"))
        self._addstr(1, 0, "Total tokens/day (input+output+cache); newest last.",
                     self._a("dim"))
        if not days:
            self._addstr(3, 4, "No dated sessions in scope.", self._a("dim"))
            self._footer(["↑↓ move", "b/Esc back", "q quit"])
            return

        mx = max(v for _, v in days)
        rows = h - 4
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        elif self.cursor >= self.scroll + rows:
            self.scroll = self.cursor - rows + 1
        barw = max(10, w - 26)
        y = 2
        for i in range(self.scroll, len(days)):
            if y >= h - 2:
                break
            day, toks = days[i]
            attr = self._a("sel") if i == self.cursor else self._a("accent")
            self._addstr(
                y, 0,
                f"{day}  {_fmt_tokens(toks):>7} {_bar(toks, mx, barw)}", attr)
            y += 1
        self._footer(["↑↓ move", "b/Esc back", "q quit"])

    # -- notes view --
    def _draw_notes(self):
        import curses
        h, w = self.scr.getmaxyx()
        self._addstr(0, 0, f" Observation notes ({len(self.notes)}) ".ljust(w - 1),
                     self._a("title"))
        rows = h - 4
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        elif self.cursor >= self.scroll + (rows // 2):
            self.scroll = self.cursor - (rows // 2) + 1
        y = 2
        for i, n in enumerate(self.notes[self.scroll:], start=self.scroll):
            if y >= h - 2:
                break
            attr = self._a("sel") if i == self.cursor else 0
            head = f"[{n.get('ts','')[:16]}] {n.get('project','?')}"
            self._addstr(y, 2, head, self._a("accent") | attr)
            y += 1
            for wrapped in _wrap(n.get("note", ""), w - 6):
                self._addstr(y, 4, wrapped)
                y += 1
            if n.get("title"):
                self._addstr(y, 4, f"↳ {n['title'][:w-8]}", self._a("dim"))
                y += 1
        if not self.notes:
            self._addstr(3, 4, "No notes yet. Open a session and press n.",
                         self._a("dim"))
        self._footer(["↑↓ move", "b/Esc back", "q quit"])

    # -- main loop --
    def run(self):
        import curses
        curses.curs_set(0)
        self.theme.init(curses)
        while True:
            self.scr.erase()
            if self.view == "picker":
                self._draw_picker()
            elif self.view == "list":
                self._draw_list()
            elif self.view == "detail":
                self._draw_detail()
            elif self.view == "dashboard":
                self._draw_dashboard()
            elif self.view == "errors":
                self._draw_errors()
            elif self.view == "timeline":
                self._draw_timeline()
            elif self.view == "notes":
                self._draw_notes()
            self.scr.refresh()

            try:
                ch = self.scr.get_wch()
            except Exception:
                continue
            if not self._handle(ch):
                break

    def _handle(self, ch):
        import curses
        self.status = ""
        # global: cycle theme
        if ch in ("t", "T"):
            self._cycle_theme()
            return True
        # global quit / step back: picker is home — q there exits, q on the
        # list returns to the picker, q elsewhere returns to the list.
        if ch in ("q", "Q"):
            if self.view == "picker":
                return False
            if self.view == "list":
                self.view = "picker"
                self.cursor = self._picker_cursor_for_sel()
                self.scroll = 0
                return True
            self.view = "list"
            self.cursor = 0
            self.scroll = 0
            return True

        if self.view == "picker":
            n = len(self.picker_opts)
            if ch in ("j", curses.KEY_DOWN):
                self.cursor = min(self.cursor + 1, n - 1)
            elif ch in ("k", curses.KEY_UP):
                self.cursor = max(0, self.cursor - 1)
            elif ch in ("\n", "\r", curses.KEY_ENTER):
                key = self.picker_opts[self.cursor][0]
                self.harness_sel = None if key == "all" else key
                self.filter = ""
                self._apply()
                self.view = "list"
                self.cursor = 0
                self.scroll = 0
            return True

        if self.view == "list":
            return self._handle_list(ch)
        if self.view == "detail":
            if ch in ("b", "\x1b"):
                self.view = "list"
            elif ch in ("n", "N"):
                self._add_note()
            elif ch in ("j", curses.KEY_DOWN):
                self.dscroll += 1
            elif ch in ("k", curses.KEY_UP):
                self.dscroll = max(0, self.dscroll - 1)
            elif ch == curses.KEY_NPAGE:
                self.dscroll += 15
            elif ch == curses.KEY_PPAGE:
                self.dscroll = max(0, self.dscroll - 15)
            elif ch in ("g",):
                self.dscroll = 0
            return True
        if self.view == "dashboard":
            if ch in ("b", "\x1b"):
                self.view = "list"
            elif ch == "N":
                self.view = "notes"
                self.cursor = 0
                self.scroll = 0
            elif ch in ("e", "E"):
                self.view = "errors"
                self.cursor = 0
                self.scroll = 0
            elif ch in ("v", "V"):
                self.view = "timeline"
                self.cursor = 0
                self.scroll = 0
            return True
        if self.view == "errors":
            n = len(aggregate(self.sessions).error_patterns)
            if ch in ("b", "\x1b"):
                self.view = "list"
                self.cursor = 0
                self.scroll = 0
            elif ch in ("j", curses.KEY_DOWN):
                self.cursor = min(self.cursor + 1, max(0, n - 1))
            elif ch in ("k", curses.KEY_UP):
                self.cursor = max(0, self.cursor - 1)
            return True
        if self.view == "timeline":
            n = len(aggregate(self.sessions).tokens_by_day)
            if ch in ("b", "\x1b"):
                self.view = "list"
                self.cursor = 0
                self.scroll = 0
            elif ch in ("j", curses.KEY_DOWN):
                self.cursor = min(self.cursor + 1, max(0, n - 1))
            elif ch in ("k", curses.KEY_UP):
                self.cursor = max(0, self.cursor - 1)
            elif ch == curses.KEY_NPAGE:
                self.cursor = min(self.cursor + 10, max(0, n - 1))
            elif ch == curses.KEY_PPAGE:
                self.cursor = max(0, self.cursor - 10)
            return True
        if self.view == "notes":
            if ch in ("b", "\x1b"):
                self.view = "list"
                self.cursor = 0
                self.scroll = 0
            elif ch in ("j", curses.KEY_DOWN):
                self.cursor = min(self.cursor + 1, max(0, len(self.notes) - 1))
            elif ch in ("k", curses.KEY_UP):
                self.cursor = max(0, self.cursor - 1)
            return True
        return True

    def _handle_list(self, ch):
        import curses
        n = len(self.sessions)
        if ch in ("j", curses.KEY_DOWN):
            self.cursor = min(self.cursor + 1, max(0, n - 1))
        elif ch in ("k", curses.KEY_UP):
            self.cursor = max(0, self.cursor - 1)
        elif ch == curses.KEY_NPAGE:
            self.cursor = min(self.cursor + 10, max(0, n - 1))
        elif ch == curses.KEY_PPAGE:
            self.cursor = max(0, self.cursor - 10)
        elif ch in ("g",):
            self.cursor = 0
        elif ch in ("G",):
            self.cursor = max(0, n - 1)
        elif ch in ("\n", "\r", curses.KEY_ENTER):
            if n:
                self.detail = self.sessions[self.cursor]
                self.dscroll = 0
                self.view = "detail"
        elif ch in ("s", "S"):
            self.sort_idx += 1
            self._apply()
        elif ch == "/":
            val = self._prompt("filter (project/title/harness, empty=clear): ")
            if val is not None:
                self.filter = val.strip()
                self.cursor = 0
                self.scroll = 0
                self._apply()
        elif ch in ("a", "A"):
            self.view = "picker"
            self.cursor = self._picker_cursor_for_sel()
            self.scroll = 0
        elif ch in ("d", "D"):
            self.view = "dashboard"
        elif ch in ("e", "E"):
            self.view = "errors"
            self.cursor = 0
            self.scroll = 0
        elif ch in ("v", "V"):
            self.view = "timeline"
            self.cursor = 0
            self.scroll = 0
        elif ch == "N":
            self.view = "notes"
            self.cursor = 0
            self.scroll = 0
        return True

    def _add_note(self):
        s = self.detail
        text = self._prompt("note> ")
        if text:
            rec = save_note(s.session_id, s.project, s.title, text.strip())
            self.notes.insert(0, rec)
            self.status = "note saved"


def _wrap(text, width):
    import textwrap
    if width < 10:
        width = 10
    return textwrap.wrap(text, width) or [""]


def run_tui(sessions, theme=None):
    import curses
    if not sessions:
        print("No sessions found under", PROJECTS)
        return
    curses.wrapper(lambda scr: App(scr, sessions, theme=theme).run())


# ---- entrypoint --------------------------------------------------------------

def main(argv):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cwd", help="only sessions recorded for this project dir")
    p.add_argument("--harness", choices=list(HARNESS_ROOTS),
                   help="only sessions from this agent (default: all)")
    p.add_argument("--limit", type=int, help="scan only the N most-recent transcripts")
    p.add_argument("--report", action="store_true",
                   help="print aggregate dashboard as text and exit (no TUI)")
    p.add_argument("--theme", choices=THEME_NAMES,
                   help=f"color theme (default: saved or {THEME_NAMES[0]}); "
                        "cycle in-app with 't'")
    args = p.parse_args(argv)

    sessions = load_sessions(cwd=args.cwd, limit=args.limit, harness=args.harness)
    if args.report:
        print(render_report(sessions))
        return 0
    run_tui(sessions, theme=args.theme)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

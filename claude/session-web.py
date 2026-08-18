#!/usr/bin/env python3
"""session-web.py — the browser front end for session-analytics.py.

session-analytics.py folds each transcript into ONE aggregate record (turns,
tokens, tool mix). That is the right shape for a table, but useless when the
question is "what actually happened in this session". This module keeps the
same parsers for the list/dashboard and adds a second, event-level pass
(`extract_events`) that replays a single transcript step by step so the page
can render a trajectory: every user prompt, context injection, hook fire,
assistant message and tool call in order, each one inspectable (summary,
full text, raw JSON).

It serves with the stdlib only (http.server + a self-contained HTML page), so
nothing has to be installed and the page works offline:

  GET /                      the single-page app
  GET /api/sessions          list rows + dashboard aggregate for the scope
  GET /api/session?path=…    one session: metrics, notes and its full event list
  POST /api/note             append an observation note (same JSONL as the TUI)
  POST /api/refresh          re-scan the transcript roots

Run it through `session-analytics.py` (which starts it by default) or directly
with `python3 session-web.py` for the same server over every project.
"""
import json
import os
import re
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MAX_TEXT = 20000    # per-event text kept for the Preview tab
MAX_RAW = 20000     # per-event raw JSON kept for the Raw tab
MAX_EVENTS = 4000   # hard cap so one runaway transcript cannot wedge the page


# ---- event extraction --------------------------------------------------------

def _clip(text, limit):
    text = text or ""
    return text if len(text) <= limit else text[:limit] + f"\n… (+{len(text) - limit} chars)"


def _oneline(text, limit=200):
    """Collapse a block of text to a single scannable line for the trace row."""
    t = re.sub(r"\s+", " ", (text or "").strip())
    return t if len(t) <= limit else t[: limit - 1] + "…"


def _blocks_text(content):
    """Join the text of a content array (claude/pi share this shape)."""
    if isinstance(content, str):
        return content
    out = []
    for c in content or []:
        if isinstance(c, dict):
            out.append(c.get("text") or c.get("content") or "")
        elif isinstance(c, str):
            out.append(c)
    return "\n".join(x for x in out if isinstance(x, str))


def _args_line(args, limit=160):
    if args is None:
        return ""
    if isinstance(args, (dict, list)):
        try:
            return _oneline(json.dumps(args, ensure_ascii=False), limit)
        except Exception:
            return _oneline(str(args), limit)
    return _oneline(str(args), limit)


def _iso_ms(a, b):
    """Milliseconds between two ISO timestamps, or None if either is missing."""
    from datetime import datetime
    try:
        pa = datetime.fromisoformat(str(a).replace("Z", "+00:00"))
        pb = datetime.fromisoformat(str(b).replace("Z", "+00:00"))
    except Exception:
        return None
    return max(0, int((pb - pa).total_seconds() * 1000))


def _mk(kind, badge, title, text="", preview="", ts="", raw=None, **extra):
    e = {
        "kind": kind,               # system|context|hook|user|assistant|tool
        "badge": badge,             # label shown in the trace gutter
        "title": _oneline(title),
        "preview": _oneline(preview),
        "text": _clip(text, MAX_TEXT),
        "thinking": "",
        "ts": ts or "",
        "dur_ms": None,
        "turn": 0,
        "step": 0,
        "tokens": {},
        "model": "",
        "tool": None,               # {name, args, result}
        "error": False,
        "raw": "",
    }
    if raw is not None:
        try:
            e["raw"] = _clip(json.dumps(raw, ensure_ascii=False, indent=2), MAX_RAW)
        except Exception:
            e["raw"] = _clip(str(raw), MAX_RAW)
    e.update(extra)
    return e


def _events_claude(rows):
    """Replay a Claude Code transcript. tool_use and its later tool_result are
    merged into one TOOL event so a call and its outcome read as one line."""
    evs = []
    pending = {}   # tool_use_id -> (event index, request timestamp)
    turn = step = 0
    for r in rows:
        t = r.get("type")
        ts = r.get("timestamp", "")
        if t == "attachment":
            att = r.get("attachment") or {}
            at = att.get("type", "?")
            body = att.get("content") or att.get("stdout") or att.get("text") or ""
            if not isinstance(body, str):
                body = json.dumps(body, ensure_ascii=False)
            if at == "hook_success":
                # hookName is usually already "Event:name"; don't repeat the event.
                hn = att.get("hookName", "?")
                ev_name = att.get("hookEvent", "?")
                name = hn if hn.startswith(ev_name) else f"{ev_name}:{hn}"
                code = att.get("exitCode", 0) or 0
                evs.append(_mk(
                    "hook", "HOOK", f"{name}  exit {code}", text=body,
                    preview=body, ts=ts, raw=r, turn=turn, error=code not in (0, None),
                    dur_ms=att.get("durationMs"),
                ))
            else:
                evs.append(_mk("context", "CONTEXT", f"{at}: {_oneline(body, 120)}",
                               text=body, ts=ts, raw=r, turn=turn))
        elif t == "system":
            sub = r.get("subtype", "system")
            body = json.dumps(r, ensure_ascii=False, indent=2)
            evs.append(_mk("system", "SYSTEM", sub, text=body, ts=ts, raw=r, turn=turn))
        elif t == "user":
            content = (r.get("message") or {}).get("content")
            if isinstance(content, str):
                st = content.strip()
                if st.startswith("<command-name>") or st.startswith("<local-command"):
                    evs.append(_mk("context", "COMMAND", st, text=st, ts=ts,
                                   raw=r, turn=turn))
                else:
                    turn += 1
                    step = 0
                    evs.append(_mk("user", "USER", st, text=st, ts=ts, raw=r, turn=turn))
                continue
            for c in content or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text":
                    txt = c.get("text", "") or ""
                    if "<system-reminder>" in txt[:400] or "<command-name>" in txt[:400]:
                        evs.append(_mk("context", "CONTEXT", txt, text=txt, ts=ts,
                                       raw=r, turn=turn))
                    else:
                        turn += 1
                        step = 0
                        evs.append(_mk("user", "USER", txt, text=txt, ts=ts,
                                       raw=r, turn=turn))
                elif c.get("type") == "tool_result":
                    body = _blocks_text(c.get("content"))
                    hit = pending.pop(c.get("tool_use_id"), None)
                    if hit is None:
                        evs.append(_mk("tool", "TOOL", "(orphan result)", text=body,
                                       preview=body, ts=ts, raw=r, turn=turn,
                                       error=bool(c.get("is_error"))))
                        continue
                    i, req_ts = hit
                    ev = evs[i]
                    ev["tool"]["result"] = _clip(body, MAX_TEXT)
                    ev["preview"] = _oneline(body)
                    ev["error"] = bool(c.get("is_error"))
                    ev["dur_ms"] = _iso_ms(req_ts, ts)
        elif t == "assistant":
            msg = r.get("message") or {}
            usage = msg.get("usage") or {}
            tokens = {
                "input": usage.get("input_tokens", 0) or 0,
                "output": usage.get("output_tokens", 0) or 0,
                "cache_read": usage.get("cache_read_input_tokens", 0) or 0,
                "cache_create": usage.get("cache_creation_input_tokens", 0) or 0,
            }
            model = msg.get("model", "")
            think = "\n".join(c.get("thinking", "") for c in msg.get("content", []) or []
                              if isinstance(c, dict) and c.get("type") == "thinking")
            texts = [c.get("text", "") for c in msg.get("content", []) or []
                     if isinstance(c, dict) and c.get("type") == "text"]
            body = "\n".join(x for x in texts if x)
            if body or think:
                step += 1
                evs.append(_mk("assistant", "ASSISTANT", body or "(thinking only)",
                               text=body, ts=ts, raw=r, turn=turn, step=step,
                               tokens=tokens, model=model,
                               thinking=_clip(think, MAX_TEXT)))
            for c in msg.get("content", []) or []:
                if not isinstance(c, dict) or c.get("type") != "tool_use":
                    continue
                step += 1
                name = c.get("name", "?")
                args = c.get("input")
                evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}",
                               ts=ts, raw=r, turn=turn, step=step, model=model,
                               tool={"name": name,
                                     "args": _clip(_args_line(args, 100000), MAX_TEXT),
                                     "result": ""}))
                if c.get("id"):
                    pending[c["id"]] = (len(evs) - 1, ts)
        if len(evs) >= MAX_EVENTS:
            break
    return evs


def _events_copilot(rows):
    """Replay a Copilot events.jsonl. tool.execution_complete merges back into
    the TOOL event its toolCallId opened."""
    evs = []
    by_id = {}
    turn = step = 0
    for r in rows:
        t = r.get("type")
        ts = r.get("timestamp", "")
        d = r.get("data") or {}
        if t == "session.start":
            ctx = d.get("context") or {}
            evs.append(_mk("system", "SESSION", f"session start — {ctx.get('cwd', '?')}",
                           text=json.dumps(d, ensure_ascii=False, indent=2),
                           ts=ts, raw=r))
        elif t == "system.message":
            body = d.get("content") or ""
            evs.append(_mk("system", "SYSTEM", "system prompt", text=body,
                           preview=body, ts=ts, raw=r, turn=turn))
        elif t == "user.message":
            body = d.get("content") or ""
            turn += 1
            step = 0
            evs.append(_mk("user", "USER", body, text=body, ts=ts, raw=r, turn=turn))
        elif t == "assistant.message":
            body = d.get("content") or ""
            model = d.get("model", "")
            if body:
                step += 1
                evs.append(_mk("assistant", "ASSISTANT", body, text=body, ts=ts,
                               raw=r, turn=turn, step=step, model=model))
            for tr in d.get("toolRequests") or []:
                step += 1
                name = tr.get("name", "?")
                args = tr.get("arguments")
                evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}", ts=ts,
                               raw=r, turn=turn, step=step, model=model,
                               preview=tr.get("intentionSummary", ""),
                               tool={"name": name,
                                     "args": _clip(_args_line(args, 100000), MAX_TEXT),
                                     "result": ""}))
                if tr.get("toolCallId"):
                    by_id[tr["toolCallId"]] = (len(evs) - 1, ts)
        elif t == "tool.execution_complete":
            res = d.get("result") or {}
            body = res.get("content") or res.get("detailedContent") or ""
            if not isinstance(body, str):
                body = json.dumps(body, ensure_ascii=False)
            failed = d.get("success") is False
            if failed:
                body = ((d.get("error") or {}).get("message") or "tool failed") + "\n" + body
            hit = by_id.pop(d.get("toolCallId"), None)
            if hit is None:
                evs.append(_mk("tool", "TOOL", d.get("toolName", "?"), text=body,
                               preview=body, ts=ts, raw=r, turn=turn, error=failed))
                continue
            i, req_ts = hit
            evs[i]["tool"]["result"] = _clip(body, MAX_TEXT)
            evs[i]["preview"] = _oneline(body)
            evs[i]["error"] = failed
            evs[i]["dur_ms"] = _iso_ms(req_ts, ts)
        elif t == "hook.end":
            ok = d.get("success", True) and d.get("exitCode", 0) in (0, None)
            evs.append(_mk("hook", "HOOK", f"{d.get('hookType', '?')}"
                           f"{'' if ok else '  failed'}",
                           text=json.dumps(d, ensure_ascii=False, indent=2),
                           ts=ts, raw=r, turn=turn, error=not ok))
        elif t == "session.shutdown":
            evs.append(_mk("system", "END", "session shutdown",
                           text=json.dumps(d, ensure_ascii=False, indent=2),
                           ts=ts, raw=r, turn=turn))
        if len(evs) >= MAX_EVENTS:
            break
    return evs


def _events_pi(rows):
    """Replay a pi session jsonl (message rows with role user/assistant/toolResult)."""
    evs = []
    by_id = {}
    turn = step = 0
    for r in rows:
        t = r.get("type")
        ts = r.get("timestamp", "")
        if t == "session":
            evs.append(_mk("system", "SESSION", f"session start — {r.get('cwd', '?')}",
                           text=json.dumps(r, ensure_ascii=False, indent=2),
                           ts=ts, raw=r))
        elif t in ("custom_message", "compaction", "session_info"):
            body = r.get("content") or r.get("summary") or r.get("name") or ""
            evs.append(_mk("context", "CONTEXT", f"{t}: {_oneline(body, 120)}",
                           text=body, ts=ts, raw=r, turn=turn))
        elif t == "message":
            m = r.get("message") or {}
            role = m.get("role")
            content = m.get("content") or []
            if role == "user":
                body = _blocks_text(content)
                turn += 1
                step = 0
                evs.append(_mk("user", "USER", body, text=body, ts=ts, raw=r, turn=turn))
            elif role == "assistant":
                u = m.get("usage") or {}
                tokens = {
                    "input": u.get("input", 0) or 0,
                    "output": u.get("output", 0) or 0,
                    "cache_read": u.get("cacheRead", 0) or 0,
                    "cache_create": u.get("cacheWrite", 0) or 0,
                }
                model = m.get("model", "")
                think = "\n".join(c.get("thinking", "") for c in content
                                  if isinstance(c, dict) and c.get("type") == "thinking")
                body = _blocks_text([c for c in content
                                     if isinstance(c, dict) and c.get("type") == "text"])
                if body or think:
                    step += 1
                    evs.append(_mk("assistant", "ASSISTANT", body or "(thinking only)",
                                   text=body, ts=ts, raw=r, turn=turn, step=step,
                                   tokens=tokens, model=model,
                                   thinking=_clip(think, MAX_TEXT)))
                for c in content:
                    if not isinstance(c, dict) or c.get("type") != "toolCall":
                        continue
                    step += 1
                    name = c.get("name", "?")
                    args = c.get("arguments")
                    evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}", ts=ts,
                                   raw=r, turn=turn, step=step, model=model,
                                   tool={"name": name,
                                         "args": _clip(_args_line(args, 100000), MAX_TEXT),
                                         "result": ""}))
                    if c.get("id"):
                        by_id[c["id"]] = (len(evs) - 1, ts)
            elif role == "toolResult":
                body = _blocks_text(content)
                failed = bool(m.get("isError"))
                hit = by_id.pop(m.get("toolCallId"), None)
                if hit is None:
                    evs.append(_mk("tool", "TOOL", m.get("toolName", "?"), text=body,
                                   preview=body, ts=ts, raw=r, turn=turn, error=failed))
                    continue
                i, req_ts = hit
                evs[i]["tool"]["result"] = _clip(body, MAX_TEXT)
                evs[i]["preview"] = _oneline(body)
                evs[i]["error"] = failed
                evs[i]["dur_ms"] = _iso_ms(req_ts, ts)
        if len(evs) >= MAX_EVENTS:
            break
    return evs


EVENT_PARSERS = {
    "claude": _events_claude,
    "copilot": _events_copilot,
    "pi": _events_pi,
}


def extract_events(rows, harness="claude"):
    """Replay one transcript into an ordered list of inspectable events."""
    return EVENT_PARSERS.get(harness, _events_claude)(rows)


# ---- JSON shaping ------------------------------------------------------------

def session_row(s):
    """The list-view shape of a Session (everything the table and filters need)."""
    return {
        "path": s.path,
        "session_id": s.session_id,
        "harness": s.harness,
        "project": s.project,
        "project_short": s.project_short,
        "title": s.title or s.session_id,
        "date": s.date,
        "day": s.day,
        "duration_min": round(s.duration_min, 1),
        "turns": s.user_turns,
        "assistant_msgs": s.assistant_msgs,
        "tools": s.total_tools,
        "tool_errors": s.tool_errors,
        "hook_errors": s.hook_errors,
        "input_tokens": s.input_tokens,
        "output_tokens": s.output_tokens,
        "cache_read": s.cache_read,
        "cache_creation": s.cache_creation,
        "total_tokens": s.total_tokens,
        "cache_ratio": round(s.cache_ratio, 4),
        "goal": s.goal,
        "models": sorted(s.models),
        "files": {"added": sorted(s.files_added), "edited": sorted(s.files_edited),
                  "removed": sorted(s.files_removed)},
        "tool_mix": s.tools.most_common(12),
        "hook_fires": s.hook_fires.most_common(12),
        "errors": s.errors[:50],
    }


def dashboard_payload(sa, sessions):
    a = sa.aggregate(sessions)
    return {
        "n_sessions": a.n_sessions,
        "turns": a.turns,
        "tool_calls": a.tool_calls,
        "tokens": a.tokens,
        "output_tokens": a.output_tokens,
        "cache_read": a.cache_read,
        "input_and_creation": a.input_and_creation,
        "tool_errors": a.tool_errors,
        "hook_errors": a.hook_errors,
        "cache_ratio": round(a.cache_ratio, 4),
        "tool_error_rate": round(a.tool_error_rate, 4),
        "goal_rate": round(a.goal_rate, 4),
        "goal_achieved": a.goal_achieved,
        "goal_not": a.goal_not,
        "goal_none": a.goal_none,
        "avg_turns": round(a.avg_turns, 1),
        "hours": round(a.total_minutes / 60.0, 1),
        "top_tools": a.top_tools.most_common(12),
        "by_project": a.by_project.most_common(12),
        "by_harness": a.by_harness.most_common(),
        "errors_by_tool": a.errors_by_tool.most_common(10),
        "error_patterns": [
            {"sig": sig, "count": c, "example": a.error_examples.get(sig, {})}
            for sig, c in a.error_patterns.most_common(12)
        ],
        "tokens_by_day": sorted(a.tokens_by_day.items()),
    }


# ---- server state ------------------------------------------------------------

class Scope:
    """Holds the scanned sessions plus a path->Session index, and parses one
    transcript's events on demand (cached until the file changes)."""

    def __init__(self, sa, cwd=None, limit=None, harness=None):
        self.sa = sa
        self.cwd = cwd
        self.limit = limit
        self.harness = harness
        self.sessions = []
        self.by_path = {}
        self._events = {}   # path -> (mtime, events)
        self._lock = threading.Lock()

    def reload(self):
        with self._lock:
            self.sessions = self.sa.load_sessions(
                cwd=self.cwd, limit=self.limit, harness=self.harness)
            self.by_path = {s.path: s for s in self.sessions}
            self._events.clear()
        return len(self.sessions)

    def events(self, path):
        s = self.by_path.get(path)
        if s is None:
            return None
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0
        cached = self._events.get(path)
        if cached and cached[0] == mtime:
            return cached[1]
        rows = list(self.sa._iter_rows(path))
        evs = extract_events(rows, s.harness)
        self._events[path] = (mtime, evs)
        return evs


def _routes(scope):
    """Build the request-serving class bound to one Scope."""
    sa = scope.sa

    class Routes(BaseHTTPRequestHandler):
        server_version = "session-analytics"

        def log_message(self, fmt, *args):
            pass  # keep the terminal for the app's own output

        def _send(self, code, body, ctype="application/json; charset=utf-8"):
            data = body if isinstance(body, bytes) else str(body).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass

        def _json(self, obj, code=200):
            self._send(code, json.dumps(obj, ensure_ascii=False, default=str))

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if u.path in ("/", "/index.html"):
                return self._send(200, PAGE, "text/html; charset=utf-8")
            if u.path == "/api/sessions":
                rows = [session_row(s) for s in scope.sessions]
                return self._json({
                    "sessions": rows,
                    "dashboard": dashboard_payload(sa, scope.sessions),
                    "scope": {"cwd": scope.cwd, "harness": scope.harness,
                              "limit": scope.limit},
                })
            if u.path == "/api/session":
                path = (q.get("path") or [""])[0]
                s = scope.by_path.get(path)
                if s is None:
                    return self._json({"error": "unknown session"}, 404)
                return self._json({
                    "session": session_row(s),
                    "events": scope.events(path),
                    "notes": sa.notes_for(s.session_id, sa.load_notes()),
                })
            return self._json({"error": "not found"}, 404)

        def do_POST(self):
            u = urlparse(self.path)
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                return self._json({"error": "bad json"}, 400)
            if u.path == "/api/refresh":
                return self._json({"n": scope.reload()})
            if u.path == "/api/note":
                s = scope.by_path.get(body.get("path", ""))
                text = (body.get("note") or "").strip()
                if s is None or not text:
                    return self._json({"error": "session and note required"}, 400)
                rec = sa.save_note(s.session_id, s.project, s.title, text)
                return self._json({"note": rec})
            return self._json({"error": "not found"}, 404)

    return Routes


def serve(sa, host="127.0.0.1", port=8765, cwd=None, limit=None, harness=None,
          open_browser=True):
    """Scan the transcripts, then serve the page until Ctrl-C."""
    scope = Scope(sa, cwd=cwd, limit=limit, harness=harness)
    n = scope.reload()
    httpd = None
    for p in range(port, port + 20):
        try:
            httpd = ThreadingHTTPServer((host, p), _routes(scope))
            port = p
            break
        except OSError:
            continue
    if httpd is None:
        print(f"no free port in {port}..{port + 19}")
        return 1
    url = f"http://{host}:{port}/"
    print(f"session analytics — {n} sessions — {url}   (Ctrl-C to stop)")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
    return 0


# ---- the page ----------------------------------------------------------------

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Session Analytics</title>
<style>
:root{
  --bg:#0f1116; --panel:#161922; --panel2:#1b1f2a; --line:#262b38;
  --fg:#dfe3ec; --dim:#8b93a7; --accent:#6ea8fe; --ok:#5fd48a; --err:#ff6b6b;
  --warn:#ffc46b; --tool:#e08a3c; --model:#a78bfa; --input:#4e9be6;
  --mono:ui-monospace,SFMono-Regular,"JetBrains Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:13px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--accent);text-decoration:none}
.hidden{display:none!important}
.top{display:flex;align-items:center;gap:14px;padding:10px 16px;
  border-bottom:1px solid var(--line);background:var(--panel)}
.top h1{font-size:14px;font-weight:600;margin:0}
.sub{color:var(--dim);font-size:12px}
.spacer{flex:1}
.tabs{display:flex;gap:4px}
.tab{padding:4px 10px;border-radius:6px;color:var(--dim);cursor:pointer;
  border:1px solid transparent}
.tab:hover{color:var(--fg)}
.tab.on{color:var(--fg);border-color:var(--line);background:var(--panel2)}
.tab.link{border-bottom:2px solid transparent;border-radius:0;padding:4px 2px}
.tab.link.on{border-bottom-color:var(--accent);background:none;border-radius:0;
  border-left:0;border-right:0;border-top:0}
input[type=search],input[type=text]{background:var(--panel2);border:1px solid var(--line);
  color:var(--fg);border-radius:6px;padding:5px 9px;font:inherit;min-width:220px}
button{background:var(--panel2);border:1px solid var(--line);color:var(--fg);
  border-radius:6px;padding:5px 10px;font:inherit;cursor:pointer}
button:hover{border-color:var(--accent)}
.wrap{padding:14px 16px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.tile .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
.tile .v{font-size:20px;font-weight:600;margin-top:2px}
.cols{display:grid;grid-template-columns:minmax(0,2.2fr) minmax(280px,1fr);
  gap:12px;margin-top:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
.card h2{font-size:12px;margin:0;padding:9px 12px;border-bottom:1px solid var(--line);
  color:var(--dim);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
.card .body{padding:8px 12px}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th{text-align:left;color:var(--dim);font-weight:600;font-size:11px;padding:7px 10px;
  border-bottom:1px solid var(--line);cursor:pointer;white-space:nowrap}
th:hover{color:var(--fg)}
td{padding:6px 10px;border-bottom:1px solid #1e2330;white-space:nowrap;
  overflow:hidden;text-overflow:ellipsis}
tr.srow{cursor:pointer}
tr.srow:hover td{background:var(--panel2)}
.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{display:inline-block;padding:1px 6px;border-radius:999px;font-size:10.5px;
  border:1px solid var(--line);color:var(--dim)}
.pill.cla{color:#9ecbff;border-color:#26405e}
.pill.cop{color:#9ae6b4;border-color:#1f4632}
.pill.pi{color:#d6bcfa;border-color:#3d2f5e}
.bar{height:6px;border-radius:3px;background:#243049}
.rowbar{display:flex;align-items:center;gap:8px;margin:3px 0}
.rowbar .lbl{width:120px;color:var(--dim);overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap}
.rowbar .n{width:52px;text-align:right;font-variant-numeric:tabular-nums}
.rowbar .track{flex:1;background:#1d2231;border-radius:3px;overflow:hidden}
.rowbar .fill{height:6px;background:var(--accent)}
/* ---- detail / trajectory ---- */
.dwrap{display:flex;flex-direction:column;height:calc(100vh - 45px)}
.chips{display:flex;align-items:center;gap:8px;padding:7px 16px;
  border-bottom:1px solid var(--line);background:var(--panel)}
.chip{padding:3px 9px;border-radius:999px;border:1px solid var(--line);
  color:var(--dim);cursor:pointer;font-size:11.5px}
.chip.on{color:var(--fg);background:var(--panel2);border-color:var(--accent)}
.map{padding:6px 16px;border-bottom:1px solid var(--line);background:var(--panel);
  overflow-x:auto}
.lane{display:flex;align-items:center;gap:6px;height:14px}
.lane .name{width:42px;color:var(--dim);font-size:10px;text-align:right;flex:none}
.lane .blocks{display:flex;gap:2px}
.blk{width:9px;height:9px;border-radius:2px;background:#2a3143;cursor:pointer;flex:none}
.blk.on{outline:1px solid var(--fg)}
.blk.err{background:var(--err)!important}
.split{display:flex;flex:1;min-height:0}
.trace{flex:1;overflow:auto;font-family:var(--mono);font-size:12px}
.ev{display:flex;gap:10px;padding:3px 12px;border-left:3px solid transparent;
  cursor:pointer;align-items:baseline}
.ev:hover{background:var(--panel2)}
.ev.on{background:#1d2431;border-left-color:var(--accent)}
.ev .badge{flex:none;width:88px;text-align:center;font-size:9.5px;letter-spacing:.05em;
  padding:1px 0;border-radius:4px;background:#242a38;color:var(--dim)}
.ev.k-user .badge{background:#1d3550;color:#9ecbff}
.ev.k-assistant .badge{background:#2e2445;color:#c3a9ff}
.ev.k-tool .badge{background:#3b2a17;color:#f0b27a}
.ev.k-hook .badge{background:#1f3a2c;color:#8fe0b0}
.ev.k-context .badge,.ev.k-system .badge{background:#242a38;color:#98a2b8}
.ev .t{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ev .arrow{color:var(--dim);flex:none}
.ev .p{flex:1;color:var(--dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ev.err .t{color:var(--err)}
.insp{width:430px;flex:none;border-left:1px solid var(--line);background:var(--panel);
  display:flex;flex-direction:column;min-height:0}
.insp .head{display:flex;align-items:center;gap:8px;padding:8px 12px;
  border-bottom:1px solid var(--line)}
.insp .head .badge{font-size:10px;padding:1px 8px;border-radius:4px;background:#242a38}
.insp .body{overflow:auto;padding:10px 12px;flex:1;min-height:0}
.kv{display:grid;grid-template-columns:120px 1fr;gap:3px 10px;font-size:12px}
.kv .k{color:var(--dim)}
pre{margin:6px 0;white-space:pre-wrap;word-break:break-word;font-family:var(--mono);
  font-size:11.5px;background:var(--panel2);border:1px solid var(--line);
  border-radius:6px;padding:8px}
.sec{margin-top:12px}
.sec h3{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.06em;
  margin:0 0 4px}
.foot{display:flex;gap:16px;padding:6px 16px;border-top:1px solid var(--line);
  background:var(--panel);color:var(--dim);font-size:11.5px;flex-wrap:wrap}
.chat .msg{max-width:900px;margin:10px auto;padding:10px 12px;border-radius:8px;
  border:1px solid var(--line);background:var(--panel)}
.chat .msg.user{border-color:#26405e}
.chat .msg .who{font-size:10.5px;color:var(--dim);text-transform:uppercase;
  letter-spacing:.06em;margin-bottom:4px}
.chat .msg .txt{white-space:pre-wrap;word-break:break-word}
.empty{color:var(--dim);padding:18px}
.ok{color:var(--ok)} .bad{color:var(--err)} .dim{color:var(--dim)}
</style></head>
<body>
<div id="app"></div>
<script>
const $ = (s, r) => (r || document).querySelector(s);
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const fmtTok = n => n >= 1e6 ? (n/1e6).toFixed(1)+"M" : n >= 1e3 ? (n/1e3).toFixed(1)+"k" : String(n||0);
const fmtInt = n => (n||0).toLocaleString();
const pct = x => Math.round((x||0)*100) + "%";
const dur = ms => ms == null ? "—" : ms >= 60000 ? (ms/60000).toFixed(1)+" m"
  : ms >= 1000 ? (ms/1000).toFixed(1)+" s" : ms+" ms";
const HS = {claude:"cla", copilot:"cop", pi:"pi"};

let DATA = null;          // {sessions, dashboard}
let LIST = {harness:"all", q:"", sort:"date", desc:true};
let DET = null;           // {session, events, notes}
let VIEW = {tab:"trajectory", sel:0, q:"", kinds:new Set()};

async function api(path, body) {
  const opt = body ? {method:"POST", body:JSON.stringify(body),
                      headers:{"Content-Type":"application/json"}} : {};
  const r = await fetch(path, opt);
  return r.json();
}

/* ---------------- index view ---------------- */
function filtered() {
  const q = LIST.q.toLowerCase();
  let rows = DATA.sessions.filter(s =>
    (LIST.harness === "all" || s.harness === LIST.harness) &&
    (!q || (s.title + " " + s.project + " " + s.harness).toLowerCase().includes(q)));
  const key = LIST.sort;
  rows = rows.slice().sort((a, b) => {
    const va = key === "date" ? a.day + a.date : a[key], vb = key === "date" ? b.day + b.date : b[key];
    return (va > vb ? 1 : va < vb ? -1 : 0) * (LIST.desc ? -1 : 1);
  });
  return rows;
}

function agg(rows) {
  const a = {n:rows.length, turns:0, tools:0, tokens:0, errs:0, cr:0, cin:0, ga:0, gn:0, mins:0};
  for (const s of rows) {
    a.turns += s.turns; a.tools += s.tools; a.tokens += s.total_tokens;
    a.errs += s.tool_errors; a.cr += s.cache_read; a.cin += s.input_tokens + s.cache_creation;
    a.mins += s.duration_min;
    if (s.goal === "achieved") a.ga++; else if (s.goal === "not_achieved") a.gn++;
  }
  return a;
}

function bars(items, color, fmt) {
  const f = fmt || fmtInt;
  const mx = Math.max(1, ...items.map(i => i[1]));
  return items.map(([n, c]) => `<div class="rowbar"><div class="lbl">${esc(n)}</div>
    <div class="n">${f(c)}</div><div class="track">
    <div class="fill" style="width:${Math.round(100*c/mx)}%;background:${color||"var(--accent)"}"></div>
    </div></div>`).join("");
}

function renderIndex() {
  const rows = filtered(), a = agg(rows), d = DATA.dashboard;
  const tabs = ["all", "claude", "copilot", "pi"].map(h =>
    `<div class="tab ${LIST.harness===h?"on":""}" data-h="${h}">${h==="all"?"All agents":h}</div>`).join("");
  const tiles = [
    ["Sessions", a.n], ["User turns", fmtInt(a.turns)], ["Tool calls", fmtInt(a.tools)],
    ["Tokens", fmtTok(a.tokens)], ["Cache hit", pct(a.cr/((a.cr+a.cin)||1))],
    ["Tool errors", a.errs], ["Active", a.mins >= 60 ? (a.mins/60).toFixed(1)+" h" : Math.round(a.mins)+" m"],
    ["GOAL ✓/✗", a.ga + " / " + a.gn],
  ].map(([k, v]) => `<div class="tile"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("");

  const head = [["date","When"],["harness","Agent"],["project_short","Project"],
    ["turns","Turns"],["tools","Tools"],["tool_errors","Err"],["total_tokens","Tokens"],
    ["cache_ratio","Cache"],["duration_min","Min"],["goal","Goal"],["title","Title"]]
    .map(([k, l]) => `<th data-k="${k}">${l}${LIST.sort===k?(LIST.desc?" ↓":" ↑"):""}</th>`).join("");

  const body = rows.map((s, i) => `<tr class="srow" data-i="${i}">
    <td>${esc(s.date)}</td>
    <td><span class="pill ${HS[s.harness]||""}">${esc(HS[s.harness]||s.harness)}</span></td>
    <td title="${esc(s.project)}">${esc(s.project_short)}</td>
    <td class="num">${s.turns}</td><td class="num">${s.tools}</td>
    <td class="num ${s.tool_errors?"bad":""}">${s.tool_errors||""}</td>
    <td class="num">${fmtTok(s.total_tokens)}</td>
    <td class="num">${pct(s.cache_ratio)}</td>
    <td class="num">${Math.round(s.duration_min)}</td>
    <td>${s.goal==="achieved"?'<span class="ok">✓</span>':s.goal==="not_achieved"?'<span class="bad">✗</span>':'<span class="dim">·</span>'}</td>
    <td title="${esc(s.title)}">${esc(s.title)}</td></tr>`).join("");

  const pats = (d.error_patterns||[]).map(p => `<div class="rowbar">
    <div class="n">${p.count}×</div><div class="lbl" style="flex:1;width:auto"
      title="${esc((p.example||{}).cmd||"")}">${esc(p.sig)}</div></div>`).join("")
    || '<div class="dim">no tool errors in scope 🎉</div>';
  const days = (d.tokens_by_day||[]).slice(-14);

  $("#app").innerHTML = `
  <div class="top"><h1>Session Analytics</h1><div class="tabs">${tabs}</div>
    <div class="spacer"></div>
    <input type="search" id="q" placeholder="filter project / title / agent" value="${esc(LIST.q)}">
    <button id="refresh">Rescan</button></div>
  <div class="wrap">
    <div class="tiles">${tiles}</div>
    <div class="cols">
      <div class="card"><h2>Sessions (${rows.length})</h2>
        <div style="max-height:60vh;overflow:auto"><table><thead><tr>${head}</tr></thead>
        <tbody>${body || '<tr><td class="empty" colspan="11">No sessions in scope.</td></tr>'}</tbody></table></div></div>
      <div>
        <div class="card"><h2>Top tools</h2><div class="body">${bars(d.top_tools||[])}</div></div>
        <div class="card" style="margin-top:12px"><h2>Busiest projects</h2>
          <div class="body">${bars(d.by_project||[], "var(--model)")}</div></div>
        <div class="card" style="margin-top:12px"><h2>Tokens per day</h2>
          <div class="body">${bars(days, "var(--tool)", fmtTok)}</div></div>
        <div class="card" style="margin-top:12px"><h2>Recurring error patterns</h2>
          <div class="body">${pats}</div></div>
      </div>
    </div>
  </div>`;

  $("#q").oninput = e => { LIST.q = e.target.value; const p = e.target.selectionStart;
    renderIndex(); const el = $("#q"); el.focus(); el.setSelectionRange(p, p); };
  $("#refresh").onclick = async () => { await api("/api/refresh", {}); await loadIndex(); };
  document.querySelectorAll(".tab[data-h]").forEach(t =>
    t.onclick = () => { LIST.harness = t.dataset.h; renderIndex(); });
  document.querySelectorAll("th[data-k]").forEach(t =>
    t.onclick = () => { const k = t.dataset.k;
      if (LIST.sort === k) LIST.desc = !LIST.desc; else { LIST.sort = k; LIST.desc = true; }
      renderIndex(); });
  document.querySelectorAll("tr.srow").forEach(tr =>
    tr.onclick = () => { location.hash = "#/s/" + encodeURIComponent(rows[+tr.dataset.i].path); });
}

/* ---------------- session detail ---------------- */
const laneOf = k => k === "assistant" ? "Model" : k === "tool" ? "Tools" : "Input";

function visibleEvents() {
  const q = VIEW.q.toLowerCase();
  return DET.events.map((e, i) => ({e, i})).filter(({e}) =>
    (!VIEW.kinds.size || VIEW.kinds.has(e.kind)) &&
    (!q || (e.title + " " + e.preview + " " + e.text).toLowerCase().includes(q)));
}

function renderDetail() {
  const s = DET.session, evs = DET.events;
  const steps = evs.filter(e => e.kind === "tool" || e.kind === "assistant").length;
  const toolMs = evs.reduce((n, e) => n + (e.dur_ms || 0), 0);
  const chips = [["user","Turns"],["assistant","Model"],["tool","Calls"],
                 ["hook","Hooks"],["context","Context"]]
    .map(([k, l]) => `<div class="chip ${VIEW.kinds.has(k)?"on":""}" data-k="${k}">${l}</div>`).join("");
  const tabs = ["trajectory", "chat", "metrics"].map(t =>
    `<div class="tab link ${VIEW.tab===t?"on":""}" data-t="${t}">${t[0].toUpperCase()+t.slice(1)}</div>`).join("");

  $("#app").innerHTML = `
  <div class="top"><a href="#/">←</a><h1>${esc(s.title)}</h1>
    <span class="sub">${esc(s.project_short)} · ${esc(s.date)} · ${esc(s.harness)}</span>
    <div class="spacer"></div><div class="tabs">${tabs}</div></div>
  <div class="dwrap">
    <div class="chips ${VIEW.tab==="trajectory"?"":"hidden"}">${chips}
      <div class="spacer"></div>
      <input type="search" id="eq" placeholder="search trajectory" value="${esc(VIEW.q)}"></div>
    <div class="map ${VIEW.tab==="trajectory"?"":"hidden"}" id="map"></div>
    <div class="split" id="split"></div>
    <div class="foot">
      <span>${s.turns} turns · ${steps} steps</span>
      <span>${s.tools} tool calls${s.tool_errors?` · <span class="bad">${s.tool_errors} failed</span>`:""}</span>
      <span>tool time ${dur(toolMs)}</span>
      <span>${Math.round(s.duration_min)} min wall</span>
      <span>cache hit ${pct(s.cache_ratio)}</span>
      <span>in ${fmtTok(s.input_tokens + s.cache_creation)} · out ${fmtTok(s.output_tokens)} · total ${fmtTok(s.total_tokens)}</span>
      <span>${esc((s.models||[]).join(", "))}</span>
    </div>
  </div>`;

  document.querySelectorAll(".tab[data-t]").forEach(t =>
    t.onclick = () => { VIEW.tab = t.dataset.t; renderDetail(); });
  if (VIEW.tab === "trajectory") {
    const vis = visibleEvents();              // keep the selection on screen
    if (vis.length && !vis.some(v => v.i === VIEW.sel)) VIEW.sel = vis[0].i;
    renderMap();
    renderTrace();
  }
  else if (VIEW.tab === "chat") renderChat();
  else renderMetrics();

  const eq = $("#eq");
  if (eq) { eq.oninput = e => { VIEW.q = e.target.value; const p = e.target.selectionStart;
      renderDetail(); const el = $("#eq"); el.focus(); el.setSelectionRange(p, p); }; }
  document.querySelectorAll(".chip[data-k]").forEach(c =>
    c.onclick = () => { const k = c.dataset.k;
      VIEW.kinds.has(k) ? VIEW.kinds.delete(k) : VIEW.kinds.add(k); renderDetail(); });
}

function renderMap() {
  // the map mirrors the trace, so a block always maps to a row you can see.
  const lanes = {Input:[], Model:[], Tools:[]};
  visibleEvents().forEach(({e, i}) => lanes[laneOf(e.kind)].push({e, i}));
  const color = k => k === "assistant" ? "var(--model)" : k === "tool" ? "var(--tool)"
    : k === "user" ? "var(--input)" : k === "hook" ? "var(--ok)" : "#39415a";
  $("#map").innerHTML = Object.entries(lanes).map(([name, items]) =>
    `<div class="lane"><div class="name">${name}</div><div class="blocks">` +
    items.map(({e, i}) => `<div class="blk ${e.error?"err":""} ${VIEW.sel===i?"on":""}"
      data-i="${i}" style="background:${color(e.kind)}"
      title="${esc(e.badge + " · " + e.title)}"></div>`).join("") +
    `</div></div>`).join("");
  document.querySelectorAll(".blk").forEach(b =>
    b.onclick = () => select(+b.dataset.i, true));
}

function renderTrace() {
  const rows = visibleEvents().map(({e, i}) => `<div class="ev k-${e.kind} ${e.error?"err":""}
    ${VIEW.sel===i?"on":""}" data-i="${i}" id="ev${i}">
    <span class="badge">${esc(e.badge)}</span>
    <span class="t">${esc(e.title)}</span>
    ${e.preview ? `<span class="arrow">→</span><span class="p">${esc(e.preview)}</span>` : ""}
  </div>`).join("");
  $("#split").innerHTML = `<div class="trace" id="trace">${rows ||
    '<div class="empty">Nothing matches this filter.</div>'}</div>
    <div class="insp" id="insp"></div>`;
  document.querySelectorAll(".ev").forEach(r => r.onclick = () => select(+r.dataset.i));
  renderInspector();
}

function select(i, scroll) {
  VIEW.sel = i;
  document.querySelectorAll(".ev").forEach(r => r.classList.toggle("on", +r.dataset.i === i));
  document.querySelectorAll(".blk").forEach(b => b.classList.toggle("on", +b.dataset.i === i));
  if (scroll) { const el = $("#ev" + i); if (el) el.scrollIntoView({block:"center"}); }
  renderInspector();
}

let ITAB = "summary";
function renderInspector() {
  const e = DET.events[VIEW.sel];
  const box = $("#insp");
  if (!box) return;
  if (!e) { box.innerHTML = '<div class="empty">Select a step.</div>'; return; }
  const t = e.tokens || {}, tot = (t.input||0)+(t.output||0)+(t.cache_read||0)+(t.cache_create||0);
  const kv = [
    ["Kind", e.badge], ["Turn / step", `${e.turn||0} · ${e.step||0}`],
    ["Status", e.error ? '<span class="bad">failed</span>' : '<span class="ok">completed</span>'],
    ["Started", e.ts ? new Date(e.ts).toLocaleString() : "—"],
    ["Duration", dur(e.dur_ms)],
    e.model ? ["Model", e.model] : null,
    e.tool ? ["Tool", e.tool.name] : null,
    tot ? ["Tokens", fmtInt(tot)] : null,
    t.output ? ["  output", fmtInt(t.output)] : null,
    t.input ? ["  input", fmtInt(t.input)] : null,
    t.cache_read ? ["  cache read", fmtInt(t.cache_read)] : null,
    t.cache_create ? ["  cache write", fmtInt(t.cache_create)] : null,
    e.thinking ? ["Thinking", fmtInt(e.thinking.length) + " chars"] : null,
  ].filter(Boolean).map(([k, v]) => `<div class="k">${esc(k)}</div><div>${v}</div>`).join("");

  const sec = (h, body) => body ? `<div class="sec"><h3>${h}</h3><pre>${esc(body)}</pre></div>` : "";
  const panes = {
    summary: `<div class="kv">${kv}</div>` +
      sec("Preview", (e.text || e.title).slice(0, 1200)) +
      (e.tool ? sec("Arguments", (e.tool.args || "").slice(0, 1200)) : ""),
    preview: sec("Text", e.text) + sec("Thinking", e.thinking) +
      (e.tool ? sec("Arguments", e.tool.args) + sec("Result", e.tool.result) : ""),
    raw: sec("Raw event", e.raw),
  };
  box.innerHTML = `<div class="head"><span class="badge">${esc(e.badge)}</span>
    <span class="sub">Turn ${e.turn||0} · Step ${e.step||0}</span><div class="spacer"></div>
    <div class="tabs">${["summary","preview","raw"].map(t =>
      `<div class="tab link ${ITAB===t?"on":""}" data-it="${t}">${t}</div>`).join("")}</div></div>
    <div class="body">${panes[ITAB] || panes.summary}</div>`;
  document.querySelectorAll("[data-it]").forEach(t =>
    t.onclick = () => { ITAB = t.dataset.it; renderInspector(); });
}

function renderChat() {
  const msgs = DET.events.filter(e => (e.kind === "user" || e.kind === "assistant") && e.text);
  $("#split").innerHTML = `<div class="trace chat" style="padding:8px 16px">${
    msgs.map(e => `<div class="msg ${e.kind}"><div class="who">${esc(e.badge)}
      ${e.model ? "· " + esc(e.model) : ""}</div>
      <div class="txt">${esc(e.text)}</div></div>`).join("") ||
    '<div class="empty">No message text captured.</div>'}</div>`;
}

function renderMetrics() {
  const s = DET.session;
  const files = f => f.length ? f.map(p => `<div>${esc(p)}</div>`).join("") : '<div class="dim">none</div>';
  const errs = (s.errors||[]).map(e => `<div class="sec"><div class="bad">✗ ${esc(e.tool)}: ${esc(e.cmd)}</div>
    <pre>${esc((e.msg||"").slice(0, 600))}</pre></div>`).join("") || '<div class="dim">none</div>';
  const notes = (DET.notes||[]).map(n => `<div class="rowbar"><div class="lbl" style="flex:1;width:auto">
    <span class="dim">[${esc((n.ts||"").slice(0,16))}]</span> ${esc(n.note)}</div></div>`).join("")
    || '<div class="dim">none yet</div>';
  $("#split").innerHTML = `<div class="trace" style="padding:12px 16px">
    <div class="tiles">${[
      ["Turns", s.turns], ["Assistant msgs", s.assistant_msgs], ["Tool calls", s.tools],
      ["Tool errors", s.tool_errors], ["Tokens", fmtTok(s.total_tokens)],
      ["Cache hit", pct(s.cache_ratio)], ["Duration", Math.round(s.duration_min)+" min"],
      ["GOAL", s.goal || "not recorded"],
    ].map(([k, v]) => `<div class="tile"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("")}</div>
    <div class="cols">
      <div class="card"><h2>Tool mix</h2><div class="body">${bars(s.tool_mix||[], "var(--tool)")}</div></div>
      <div class="card"><h2>Hook fires</h2><div class="body">${bars(s.hook_fires||[], "var(--ok)")
        || '<div class="dim">none</div>'}</div></div>
    </div>
    <div class="cols">
      <div class="card"><h2>Files changed</h2><div class="body">
        <div class="ok">+ added</div>${files(s.files.added)}
        <div class="sec"><div class="dim">~ edited</div>${files(s.files.edited)}</div>
        <div class="sec"><div class="bad">- removed</div>${files(s.files.removed)}</div></div></div>
      <div class="card"><h2>Notes</h2><div class="body">${notes}
        <div class="sec"><input type="text" id="note" placeholder="observation…">
        <button id="addnote">Save</button></div></div></div>
    </div>
    <div class="card" style="margin-top:12px"><h2>Tool errors</h2><div class="body">${errs}</div></div>
  </div>`;
  const btn = $("#addnote");
  if (btn) btn.onclick = async () => {
    const v = $("#note").value.trim();
    if (!v) return;
    const r = await api("/api/note", {path: DET.session.path, note: v});
    if (r.note) { DET.notes.unshift(r.note); renderDetail(); }
  };
}

/* ---------------- routing ---------------- */
async function loadIndex() {
  $("#app").innerHTML = '<div class="empty">Scanning transcripts…</div>';
  DATA = await api("/api/sessions");
  renderIndex();
}

async function route() {
  const h = location.hash || "#/";
  if (h.startsWith("#/s/")) {
    const path = decodeURIComponent(h.slice(4));
    $("#app").innerHTML = '<div class="empty">Loading session…</div>';
    DET = await api("/api/session?path=" + encodeURIComponent(path));
    if (DET.error) { location.hash = "#/"; return; }
    VIEW = {tab:"trajectory", sel:0, q:"", kinds:new Set()};
    renderDetail();
    return;
  }
  if (!DATA) await loadIndex(); else renderIndex();
}

window.addEventListener("hashchange", route);
window.addEventListener("keydown", e => {
  if (!DET || VIEW.tab !== "trajectory" || /input/i.test(e.target.tagName)) return;
  if (e.key === "j" || e.key === "ArrowDown") { select(Math.min(VIEW.sel+1, DET.events.length-1), true); e.preventDefault(); }
  if (e.key === "k" || e.key === "ArrowUp") { select(Math.max(VIEW.sel-1, 0), true); e.preventDefault(); }
  if (e.key === "Escape") location.hash = "#/";
});
route();
</script></body></html>
"""


def _load_analytics():
    """Import session-analytics.py from next to this file (hyphens block a
    normal import), so `python3 session-web.py` works standalone."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "session-analytics.py")
    spec = importlib.util.spec_from_file_location("session_analytics", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


if __name__ == "__main__":
    raise SystemExit(serve(_load_analytics()))

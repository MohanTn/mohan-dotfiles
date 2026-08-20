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
        # unclipped sizes of what this event contributed, so token attribution
        # is not skewed by the MAX_TEXT clipping done for display.
        "chars": {},                # think|text|args|result -> character count
        "mid": "",                  # response id: events of one API response share it
        "think_blocks": 0,          # reasoning blocks in this response, text or not
        "est": {},                  # filled in by token_report()
    }
    if raw is not None:
        try:
            e["raw"] = _clip(json.dumps(raw, ensure_ascii=False, indent=2), MAX_RAW)
        except Exception:
            e["raw"] = _clip(str(raw), MAX_RAW)
    e.update(extra)
    return e


def _raw_len(x):
    """Character size of a tool argument blob, before any clipping."""
    if x is None:
        return 0
    if isinstance(x, str):
        return len(x)
    try:
        return len(json.dumps(x, ensure_ascii=False))
    except Exception:
        return len(str(x))


def _events_claude(rows):
    """Replay a Claude Code transcript. tool_use and its later tool_result are
    merged into one TOOL event so a call and its outcome read as one line."""
    evs = []
    pending = {}   # tool_use_id -> (event index, request timestamp)
    counted = {}   # message id -> its usage, emptied once attached to an event
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
                    dur_ms=att.get("durationMs"), chars={"text": len(body)},
                ))
            else:
                evs.append(_mk("context", "CONTEXT", f"{at}: {_oneline(body, 120)}",
                               text=body, ts=ts, raw=r, turn=turn,
                               chars={"text": len(body)}))
        elif t == "system":
            sub = r.get("subtype", "system")
            body = json.dumps(r, ensure_ascii=False, indent=2)
            evs.append(_mk("system", "SYSTEM", sub, text=body, ts=ts, raw=r, turn=turn,
                           chars={"text": len(body)}))
        elif t == "user":
            content = (r.get("message") or {}).get("content")
            if isinstance(content, str):
                st = content.strip()
                if st.startswith("<command-name>") or st.startswith("<local-command"):
                    evs.append(_mk("context", "COMMAND", st, text=st, ts=ts,
                                   raw=r, turn=turn, chars={"text": len(st)}))
                else:
                    turn += 1
                    step = 0
                    evs.append(_mk("user", "USER", st, text=st, ts=ts, raw=r, turn=turn,
                                   chars={"text": len(st)}))
                continue
            for c in content or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text":
                    txt = c.get("text", "") or ""
                    if "<system-reminder>" in txt[:400] or "<command-name>" in txt[:400]:
                        evs.append(_mk("context", "CONTEXT", txt, text=txt, ts=ts,
                                       raw=r, turn=turn, chars={"text": len(txt)}))
                    else:
                        turn += 1
                        step = 0
                        evs.append(_mk("user", "USER", txt, text=txt, ts=ts,
                                       raw=r, turn=turn, chars={"text": len(txt)}))
                elif c.get("type") == "tool_result":
                    body = _blocks_text(c.get("content"))
                    hit = pending.pop(c.get("tool_use_id"), None)
                    if hit is None:
                        evs.append(_mk("tool", "TOOL", "(orphan result)", text=body,
                                       preview=body, ts=ts, raw=r, turn=turn,
                                       error=bool(c.get("is_error")),
                                       chars={"result": len(body)}))
                        continue
                    i, req_ts = hit
                    ev = evs[i]
                    ev["tool"]["result"] = _clip(body, MAX_TEXT)
                    ev["preview"] = _oneline(body)
                    ev["error"] = bool(c.get("is_error"))
                    ev["dur_ms"] = _iso_ms(req_ts, ts)
                    ev["chars"]["result"] = len(body)
        elif t == "assistant":
            msg = r.get("message") or {}
            mid = msg.get("id") or f"row{len(evs)}"
            # One API response is written as several rows sharing message.id, each
            # repeating the same usage. Hold it against the id and hand it to the
            # first event built for that response, whichever row that comes from.
            if mid not in counted:
                counted[mid] = {
                    "input": (msg.get("usage") or {}).get("input_tokens", 0) or 0,
                    "output": (msg.get("usage") or {}).get("output_tokens", 0) or 0,
                    "cache_read": (msg.get("usage") or {}).get(
                        "cache_read_input_tokens", 0) or 0,
                    "cache_create": (msg.get("usage") or {}).get(
                        "cache_creation_input_tokens", 0) or 0,
                }
            model = msg.get("model", "")
            blocks = [c for c in msg.get("content", []) or [] if isinstance(c, dict)]
            # Reasoning is often stored as an empty block plus a signature, so count
            # the blocks as well as their text: token_report needs to know a response
            # was thinking even when the text of that thinking was never written down.
            think = "\n".join(c.get("thinking", "") for c in blocks
                              if c.get("type") == "thinking")
            nthink = sum(1 for c in blocks
                         if c.get("type") in ("thinking", "redacted_thinking"))
            body = "\n".join(x for x in
                             (c.get("text", "") for c in blocks
                              if c.get("type") == "text") if x)
            if body or think or nthink:
                step += 1
                evs.append(_mk("assistant", "ASSISTANT",
                               body or think or "(reasoning, text not recorded)",
                               text=body, ts=ts, raw=r, turn=turn, step=step,
                               tokens=counted[mid], model=model, mid=mid,
                               think_blocks=nthink,
                               chars={"text": len(body), "think": len(think)},
                               thinking=_clip(think, MAX_TEXT)))
                counted[mid] = {}
                nthink = 0
            for c in blocks:
                if c.get("type") != "tool_use":
                    continue
                step += 1
                name = c.get("name", "?")
                args = c.get("input")
                evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}",
                               ts=ts, raw=r, turn=turn, step=step, model=model,
                               mid=mid, tokens=counted[mid], think_blocks=nthink,
                               chars={"args": _raw_len(args)},
                               tool={"name": name,
                                     "args": _clip(_args_line(args, 100000), MAX_TEXT),
                                     "result": ""}))
                counted[mid] = {}
                nthink = 0
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
            body = json.dumps(d, ensure_ascii=False, indent=2)
            evs.append(_mk("system", "SESSION", f"session start — {ctx.get('cwd', '?')}",
                           text=body, ts=ts, raw=r, chars={"text": len(body)}))
        elif t == "system.message":
            body = d.get("content") or ""
            evs.append(_mk("system", "SYSTEM", "system prompt", text=body,
                           preview=body, ts=ts, raw=r, turn=turn,
                           chars={"text": len(body)}))
        elif t == "user.message":
            body = d.get("content") or ""
            turn += 1
            step = 0
            evs.append(_mk("user", "USER", body, text=body, ts=ts, raw=r, turn=turn,
                           chars={"text": len(body)}))
        elif t == "assistant.message":
            body = d.get("content") or ""
            model = d.get("model", "")
            mid = d.get("id") or f"row{len(evs)}"
            if body:
                step += 1
                evs.append(_mk("assistant", "ASSISTANT", body, text=body, ts=ts,
                               raw=r, turn=turn, step=step, model=model, mid=mid,
                               chars={"text": len(body)}))
            for tr in d.get("toolRequests") or []:
                step += 1
                name = tr.get("name", "?")
                args = tr.get("arguments")
                evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}", ts=ts,
                               raw=r, turn=turn, step=step, model=model, mid=mid,
                               preview=tr.get("intentionSummary", ""),
                               chars={"args": _raw_len(args)},
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
                               preview=body, ts=ts, raw=r, turn=turn, error=failed,
                               chars={"result": len(body)}))
                continue
            i, req_ts = hit
            evs[i]["tool"]["result"] = _clip(body, MAX_TEXT)
            evs[i]["preview"] = _oneline(body)
            evs[i]["error"] = failed
            evs[i]["dur_ms"] = _iso_ms(req_ts, ts)
            evs[i]["chars"]["result"] = len(body)
        elif t == "hook.end":
            ok = d.get("success", True) and d.get("exitCode", 0) in (0, None)
            hbody = json.dumps(d, ensure_ascii=False, indent=2)
            evs.append(_mk("hook", "HOOK", f"{d.get('hookType', '?')}"
                           f"{'' if ok else '  failed'}",
                           text=hbody, ts=ts, raw=r, turn=turn, error=not ok,
                           chars={"text": len(hbody)}))
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
                           text=body, ts=ts, raw=r, turn=turn,
                           chars={"text": len(body)}))
        elif t == "message":
            m = r.get("message") or {}
            role = m.get("role")
            content = m.get("content") or []
            mid = m.get("id") or f"row{len(evs)}"
            if role == "user":
                body = _blocks_text(content)
                turn += 1
                step = 0
                evs.append(_mk("user", "USER", body, text=body, ts=ts, raw=r, turn=turn,
                               chars={"text": len(body)}))
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
                                   tokens=tokens, model=model, mid=mid,
                                   chars={"text": len(body), "think": len(think)},
                                   thinking=_clip(think, MAX_TEXT)))
                    tokens = {}
                for c in content:
                    if not isinstance(c, dict) or c.get("type") != "toolCall":
                        continue
                    step += 1
                    name = c.get("name", "?")
                    args = c.get("arguments")
                    evs.append(_mk("tool", "TOOL", f"{name} {_args_line(args)}", ts=ts,
                                   raw=r, turn=turn, step=step, model=model, mid=mid,
                                   tokens=tokens, chars={"args": _raw_len(args)},
                                   tool={"name": name,
                                         "args": _clip(_args_line(args, 100000), MAX_TEXT),
                                         "result": ""}))
                    tokens = {}
                    if c.get("id"):
                        by_id[c["id"]] = (len(evs) - 1, ts)
            elif role == "toolResult":
                body = _blocks_text(content)
                failed = bool(m.get("isError"))
                hit = by_id.pop(m.get("toolCallId"), None)
                if hit is None:
                    evs.append(_mk("tool", "TOOL", m.get("toolName", "?"), text=body,
                                   preview=body, ts=ts, raw=r, turn=turn, error=failed,
                                   chars={"result": len(body)}))
                    continue
                i, req_ts = hit
                evs[i]["tool"]["result"] = _clip(body, MAX_TEXT)
                evs[i]["preview"] = _oneline(body)
                evs[i]["error"] = failed
                evs[i]["dur_ms"] = _iso_ms(req_ts, ts)
                evs[i]["chars"]["result"] = len(body)
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


# ---- token attribution -------------------------------------------------------
# Transcripts record token usage per API response, never per content block, so
# no file says "50k of the output was thinking". What they do record is the
# exact size of every response and the exact text of every part of it, so the
# split below is the response's real token count divided by character share.
# Totals are exact; the slices inside them are estimates, and the payload says
# so, because acting on a made-up number is worse than acting on none.

CHARS_PER_TOKEN = 4.0   # fallback only, for harnesses that log no usage at all

OUT_LABELS = {"think": "Thinking", "text": "Reply text", "args": "Tool calls"}
CTX_LABELS = {
    "boot": "System prompt & tools",
    "user": "User prompts",
    "result": "Tool results",
    "context": "Context injections",
    "hook": "Hook output",
    "model": "Model turns re-read",
    # growth the transcript does not spell out: tool schemas loaded mid-session,
    # skill bodies, per-turn reminders the harness never writes to the log.
    "other": "Not in the transcript",
}


def _share(total, parts):
    """Split `total` across {key: weight} proportionally, without losing a token
    to rounding (the largest slice absorbs the remainder)."""
    weight = sum(parts.values())
    if total <= 0 or weight <= 0:
        return {}
    out = {k: int(total * w / weight) for k, w in parts.items() if w > 0}
    if out:
        big = max(out, key=lambda k: out[k])
        out[big] += total - sum(out.values())
    return out


def _ctx_of(tokens):
    """Everything the model had to read for one request."""
    return ((tokens.get("input", 0) or 0) + (tokens.get("cache_read", 0) or 0)
            + (tokens.get("cache_create", 0) or 0))


def token_report(events):
    """Where a session's tokens went, and a per-event estimate written back onto
    the events (`est`) so a single step can show its own share.

    Output side: a response's output tokens are split over its reply text and
    tool-call arguments by character share. Reasoning is the residual: Claude
    stores thinking blocks with the text stripped (an empty string plus a
    signature), so the only honest measure of it is "the tokens this response
    was billed minus the tokens its visible text can account for".

    Context side: each request's context is compared with the previous one and
    the growth is attributed to whatever entered the conversation in between
    (tool results, injections, prompts, the model's own last turn). The first
    request also carries the system prompt and tool definitions, which no row
    records, so what the visible text cannot explain lands in "System prompt".

    Both sides convert characters to tokens with a ratio calibrated on this
    session's own responses rather than a guessed constant.
    """
    out_parts = {k: 0 for k in OUT_LABELS}
    ctx_parts = {k: 0 for k in CTX_LABELS}
    by_tool = {}
    context_reads = requests = cache_read = 0

    # --- group events by the response they belong to -------------------------
    groups, index = [], {}
    for i, e in enumerate(events):
        key = e.get("mid") or f"_{i}"
        g = index.get(key)
        if g is None:
            g = {"out": 0, "think_blocks": 0, "evs": []}
            index[key] = g
            groups.append(g)
        g["evs"].append(e)
        g["out"] = g["out"] or (e.get("tokens") or {}).get("output", 0) or 0
        g["think_blocks"] += e.get("think_blocks", 0) or 0

    def weigh(g):
        """{(event, part): characters} for everything this response generated."""
        w = {}
        for e in g["evs"]:
            if e.get("kind") not in ("assistant", "tool"):
                continue
            c = e.get("chars") or {}
            for k in OUT_LABELS:
                if c.get(k):
                    w[(id(e), k)] = c[k]
        return w

    gen = [g for g in groups
           if any(e.get("kind") in ("assistant", "tool") for e in g["evs"])]
    exact = any(g["out"] for g in gen)

    # --- calibrate: chars per token, measured on responses that did not think
    seen_chars = billed = 0
    for g in gen:
        if g["out"] and not g["think_blocks"]:
            seen_chars += sum(weigh(g).values())
            billed += g["out"]
    ratio = seen_chars / billed if billed and seen_chars else CHARS_PER_TOKEN
    ratio = min(8.0, max(1.5, ratio))

    # --- output: visible parts by character share, reasoning as the residual --
    for g in gen:
        weights = weigh(g)
        visible = sum(weights.values())
        out = g["out"] or (0 if exact else int(visible / ratio))
        if out <= 0:
            continue
        if g["think_blocks"]:
            spend = min(out, int(visible / ratio)) if visible else 0
        else:
            spend = out                      # nothing hidden: it is all visible
        split = _share(spend, weights)
        for (eid, k), n in split.items():
            out_parts[k] += n
        for e in g["evs"]:
            mine = {k: v for (eid, k), v in split.items() if eid == id(e)}
            if mine:
                e["est"]["out"] = sum(mine.values())
                e["est"]["out_parts"] = {OUT_LABELS[k]: v for k, v in mine.items()}
        rest = out - spend
        if rest > 0:
            out_parts["think"] += rest
            carrier = g["evs"][0]
            carrier["est"]["think"] = carrier["est"].get("think", 0) + rest
            carrier["est"]["out"] = carrier["est"].get("out", 0) + rest

    # --- context: attribute each request's growth to what arrived before it ---
    pending = {k: 0 for k in CTX_LABELS}
    pending_tool = {}
    pending_evs = []
    prev_ctx = 0
    for e in events:
        tokens = e.get("tokens") or {}
        ctx = _ctx_of(tokens)
        if ctx:
            requests += 1
            context_reads += ctx
            cache_read += tokens.get("cache_read", 0) or 0
            grew = ctx - prev_ctx if prev_ctx else ctx
            prev_ctx = ctx
            if grew > 0:
                seen = sum(pending.values())
                explained = min(grew, int(seen / ratio)) if seen else 0
                for k, n in _share(explained, pending).items():
                    ctx_parts[k] += n
                for ev, chars in pending_evs:
                    if seen:
                        ev["est"]["ctx"] = int(explained * chars / seen)
                for name, chars in pending_tool.items():
                    if seen:
                        by_tool[name] = by_tool.get(name, 0) + int(explained * chars / seen)
                rest = grew - explained
                if rest > 0:
                    ctx_parts["boot" if requests == 1 else "other"] += rest
            pending = {k: 0 for k in CTX_LABELS}
            pending_tool = {}
            pending_evs = []
        c = e.get("chars") or {}
        kind = e.get("kind")
        bucket = ("user" if kind == "user" else "hook" if kind == "hook"
                  else "model" if kind == "assistant" else "context")
        own = (c.get("text", 0) + c.get("think", 0)
               + (c.get("args", 0) if kind != "tool" else 0))
        if own:
            pending[bucket] += own
            pending_evs.append((e, own))
        if kind == "tool":
            grown = c.get("result", 0) + c.get("args", 0)
            if grown:
                pending["result" if c.get("result") else "model"] += grown
                pending_evs.append((e, grown))
                if c.get("result"):
                    name = (e.get("tool") or {}).get("name", "?")
                    pending_tool[name] = pending_tool.get(name, 0) + grown

    def rows(parts, labels):
        total = sum(parts.values()) or 1
        return [{"label": labels[k], "tokens": v, "pct": round(100.0 * v / total, 1)}
                for k, v in sorted(parts.items(), key=lambda kv: -kv[1]) if v > 0]

    out_total = sum(out_parts.values())
    ctx_total = sum(ctx_parts.values())
    tools = sorted(by_tool.items(), key=lambda kv: -kv[1])[:10]
    return {
        "exact": exact,
        "ratio": round(ratio, 2),
        "output": {"total": out_total, "rows": rows(out_parts, OUT_LABELS)},
        "context": {"total": ctx_total, "rows": rows(ctx_parts, CTX_LABELS)},
        "by_tool": [{"label": n, "tokens": v,
                     "pct": round(100.0 * v / (ctx_total or 1), 1)} for n, v in tools],
        "reads": {
            "context_reads": context_reads,
            "requests": requests,
            "cache_read": cache_read,
            "reread": round(context_reads / ctx_total, 1) if ctx_total else 0,
        },
    }


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
        """(events, token report) for one transcript, parsed once per mtime."""
        s = self.by_path.get(path)
        if s is None:
            return None, None
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0
        cached = self._events.get(path)
        if cached and cached[0] == mtime:
            return cached[1], cached[2]
        rows = list(self.sa._iter_rows(path))
        evs = extract_events(rows, s.harness)
        rep = token_report(evs)   # also writes each event's own estimate
        self._events[path] = (mtime, evs, rep)
        return evs, rep


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
                events, tokens = scope.events(path)
                return self._json({
                    "session": session_row(s),
                    "events": events,
                    "tokens": tokens,
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
  --bg:#ffffff; --side:#f7f8fa; --panel:#fbfbfd; --line:#e5e7ec; --line2:#eef0f4;
  --fg:#1f2328; --dim:#69707d; --faint:#9aa1ac;
  --accent:#3b6ef6; --accbg:#e9eefb; --ok:#1a7f4b; --err:#c8342b;
  --user:#2563eb; --userbg:#e8f0ff; --asst:#7442cf; --asstbg:#f2ecfd;
  --tool:#b8620f; --toolbg:#fcf0e2; --ctx:#0f766e; --ctxbg:#e6f4f2;
  --sys:#5b6472; --sysbg:#eef0f4; --hook:#1a7f4b; --hookbg:#e7f4ec;
  --mono:ui-monospace,SFMono-Regular,"JetBrains Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--fg);
  font:13px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--accent);text-decoration:none}
.hidden{display:none!important}
.spacer{flex:1}
.dim{color:var(--dim)} .ok{color:var(--ok)} .bad{color:var(--err)}
.num{text-align:right;font-variant-numeric:tabular-nums}
#app{height:100vh;display:flex;overflow:hidden}
input[type=search],input[type=text]{background:#fff;border:1px solid var(--line);
  color:var(--fg);border-radius:7px;padding:5px 9px;font:inherit;min-width:0}
input:focus{outline:none;border-color:var(--accent)}
button{background:#fff;border:1px solid var(--line);color:var(--fg);border-radius:7px;
  padding:5px 10px;font:inherit;cursor:pointer}
button:hover{border-color:#c9cedb;background:#fafbfc}

/* ---------- sidebar ---------- */
.side{width:266px;flex:none;background:var(--side);border-right:1px solid var(--line);
  display:flex;flex-direction:column;min-height:0}
.side.off{display:none}
.brand{display:flex;align-items:center;gap:7px;padding:13px 14px 11px}
.brand .logo{font-weight:700;font-size:15px;letter-spacing:-.02em}
.brand .tag{font-size:8.5px;font-weight:700;letter-spacing:.09em;background:#15181d;
  color:#fff;padding:2px 5px;border-radius:4px}
.brand .fold{margin-left:auto;border:0;background:none;color:var(--faint);padding:2px 4px}
.newbtn{margin:0 12px 12px;padding:7px 10px;border-radius:9px;width:calc(100% - 24px);
  display:flex;align-items:center;justify-content:center;gap:6px;font-size:12.5px}
.sidehead{display:flex;align-items:center;gap:6px;padding:0 14px 6px;color:var(--faint);
  font-size:11px}
.sidehead .ic{cursor:pointer;padding:0 2px}
.sidehead .ic:hover{color:var(--fg)}
.sidesearch{padding:0 12px 8px;display:flex;gap:6px}
.sidesearch input{flex:1}
.hpills{display:flex;gap:4px;padding:0 12px 8px}
.hp{font-size:10.5px;color:var(--dim);border:1px solid var(--line);background:#fff;
  border-radius:999px;padding:1px 8px;cursor:pointer}
.hp.on{color:var(--accent);border-color:var(--accent);background:var(--accbg)}
.tree{flex:1;overflow:auto;padding:0 8px 10px}
.wsrow{display:flex;align-items:center;gap:6px;padding:5px 6px;border-radius:7px;
  cursor:pointer;color:var(--dim);font-size:12.5px}
.wsrow:hover{background:#edeff3;color:var(--fg)}
.wsrow .car{width:10px;color:var(--faint);font-size:9px}
.wsrow .n{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.wsrow .c{color:var(--faint);font-size:11px}
.ses{display:flex;align-items:center;gap:8px;padding:5px 8px 5px 24px;border-radius:7px;
  cursor:pointer;font-size:12.5px;color:#3b424e}
.ses:hover{background:#edeff3}
.ses.on{background:#e6e9ef;color:var(--fg)}
.ses .nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ses .age{color:var(--faint);font-size:11px;flex:none}
.ses .dot{width:5px;height:5px;border-radius:50%;flex:none}
.sidefoot{border-top:1px solid var(--line);padding:9px 14px;color:var(--dim);
  display:flex;align-items:center;gap:8px;font-size:12px}

/* ---------- main ---------- */
.main{flex:1;display:flex;flex-direction:column;min-width:0;min-height:0}
.hdr{display:flex;align-items:center;gap:12px;padding:8px 16px 0;border-bottom:1px solid var(--line)}
.hdr .title{font-weight:600;max-width:38vw;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap;padding-bottom:9px}
.hdr .mode{color:var(--dim);font-size:12px;padding-bottom:9px}
.hdr .fold{border:0;background:none;color:var(--faint);padding:0 2px 9px}
.tabs{display:flex;gap:16px;align-self:flex-end}
.tab{padding:5px 2px 8px;color:var(--dim);cursor:pointer;border-bottom:2px solid transparent;
  font-size:12.5px}
.tab:hover{color:var(--fg)}
.tab.on{color:var(--accent);border-bottom-color:var(--accent)}
.hdr .btn{margin-bottom:8px}

.tbar{display:flex;align-items:center;gap:10px;padding:5px 16px;
  border-bottom:1px solid var(--line2);color:var(--dim);font-size:12px}
.tg{display:flex;align-items:center;gap:5px;cursor:pointer;padding:2px 7px;border-radius:7px;
  border:1px solid transparent}
.tg:hover{background:#f2f4f7}
.tg.on{background:var(--accbg);color:var(--accent);border-color:#cfdcfb}
.tbar input{width:210px}

.map{padding:5px 16px 6px;border-bottom:1px solid var(--line);background:var(--panel);
  overflow-x:auto}
.lane{display:flex;align-items:center;gap:6px;height:13px}
.lane .name{width:36px;flex:none;text-align:right;color:var(--faint);font-size:9.5px}
.lane .blocks{display:flex;gap:2px}
.blk{width:9px;height:8px;border-radius:2px;flex:none;cursor:pointer}
.blk.on{outline:2px solid #1f2328;outline-offset:1px}
.blk.err{background:var(--err)!important}

.split{flex:1;display:flex;min-height:0}
.trace{flex:1;overflow:auto;min-width:0}
.ev{display:flex;align-items:baseline;gap:9px;padding:3px 12px 3px 0;
  border-left:3px solid transparent;cursor:pointer;font-family:var(--mono);font-size:11.5px}
.ev:hover{background:#f5f6f9}
.ev.on{background:#eef2fd;border-left-color:var(--accent)}
.ev .gut{width:56px;flex:none;text-align:right;color:var(--faint);font-size:9.5px;
  font-family:ui-sans-serif,system-ui,sans-serif}
.ev .badge{width:74px;flex:none;text-align:center;font-size:9px;letter-spacing:.07em;
  padding:1px 0;border-radius:4px;background:var(--sysbg);color:var(--sys);
  font-family:ui-sans-serif,system-ui,sans-serif}
.ev.k-user .badge{background:var(--userbg);color:var(--user)}
.ev.k-assistant .badge{background:var(--asstbg);color:var(--asst)}
.ev.k-tool .badge{background:var(--toolbg);color:var(--tool)}
.ev.k-hook .badge{background:var(--hookbg);color:var(--hook)}
.ev.k-context .badge{background:var(--ctxbg);color:var(--ctx)}
.ev .nm{flex:none;font-weight:700;color:var(--fg)}
.ev .t{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  color:#3d4450}
.ev .arrow{flex:none;color:var(--faint)}
.ev .p{flex:1 1 42%;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  color:var(--dim)}
.ev.err .t,.ev.err .nm{color:var(--err)}
.ev.turnstart{border-top:1px solid var(--line2)}
.ev.prose .t{font-family:ui-sans-serif,system-ui,sans-serif;font-size:12.5px}

.insp{width:424px;flex:none;border-left:1px solid var(--line);display:flex;
  flex-direction:column;min-height:0;background:var(--bg)}
.insp .head{display:flex;align-items:center;gap:9px;padding:8px 12px}
.insp .head .badge{font-size:9px;letter-spacing:.07em;padding:1px 7px;border-radius:4px;
  background:var(--toolbg);color:var(--tool)}
.insp .head .sub{color:var(--faint);font-size:11.5px}
.insp .head .x{border:0;background:none;color:var(--faint);padding:0 4px;font-size:15px}
.itabs{display:flex;gap:15px;padding:0 12px;border-bottom:1px solid var(--line2)}
.ibody{flex:1;overflow:auto;padding:10px 13px 24px;min-height:0}
.kv{display:grid;grid-template-columns:104px 1fr;gap:5px 12px;font-size:12px}
.kv .k{color:var(--dim)}
.sec{margin-top:15px}
.sec h3{font-size:11.5px;font-weight:600;color:var(--fg);margin:0 0 5px;
  display:flex;align-items:center;gap:5px}
.sec h3 .car{color:var(--faint);font-size:9px}
pre{margin:5px 0;white-space:pre-wrap;word-break:break-word;font-family:var(--mono);
  font-size:11px;line-height:1.5;background:#f7f8fa;border:1px solid var(--line);
  border-radius:7px;padding:8px 9px;color:#333a45}
pre.plain{background:none;border:0;padding:0;color:#3d4450}

.foot{display:flex;gap:0;padding:6px 16px;border-top:1px solid var(--line);
  background:var(--panel);color:var(--dim);font-size:11.5px;flex-wrap:wrap}
.foot span{padding:0 12px;border-right:1px solid var(--line)}
.foot span:first-child{padding-left:0}
.foot span:last-child{border-right:0}

.pane{flex:1;overflow:auto;min-height:0}
.chat{padding:14px 0 40px}
.msg{max-width:840px;margin:0 auto 14px;padding:0 16px}
.msg .who{font-size:10px;letter-spacing:.07em;color:var(--faint);margin-bottom:4px}
.msg .txt{white-space:pre-wrap;word-break:break-word;background:#fff;border:1px solid var(--line);
  border-radius:10px;padding:10px 12px}
.msg.user .txt{background:#f4f7ff;border-color:#dbe4fb}

.hero{flex:1;overflow:auto;padding:0 0 40px}
.heroin{max-width:1100px;margin:0 auto;padding:56px 20px 0;text-align:center}
.heroin h1{font-size:26px;font-weight:600;margin:0 0 6px;letter-spacing:-.02em}
.heroin .p{color:var(--dim);margin-bottom:26px}
.badgepv{display:inline-block;font-size:10px;color:var(--accent);background:var(--accbg);
  border-radius:5px;padding:2px 7px;vertical-align:middle;margin-left:6px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;
  text-align:left}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
.tile .k{color:var(--dim);font-size:10.5px;text-transform:uppercase;letter-spacing:.06em}
.tile .v{font-size:20px;font-weight:600;margin-top:2px}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;
  margin-top:12px;text-align:left}
.card{background:var(--bg);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.card h2{font-size:11px;margin:0;padding:9px 12px;border-bottom:1px solid var(--line2);
  color:var(--dim);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
.card .body{padding:9px 12px}
.rowbar{display:flex;align-items:center;gap:8px;margin:3px 0;font-size:12px}
.rowbar .lbl{width:120px;color:var(--dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rowbar .n{width:54px;text-align:right;font-variant-numeric:tabular-nums}
.rowbar .track{flex:1;background:#eef0f4;border-radius:3px;overflow:hidden}
.rowbar .fill{height:6px;background:var(--accent)}
.empty{color:var(--faint);padding:18px;font-size:12.5px}
.mwrap{padding:14px 16px 40px}
.sbar{display:flex;height:11px;border-radius:6px;overflow:hidden;background:#eef0f4;
  margin:4px 0 9px}
.sbar i{height:100%;display:block}
.tgrp{margin-bottom:16px}
.tgrp .hd{display:flex;align-items:baseline;gap:8px;font-size:12px;margin-bottom:2px}
.tgrp .hd b{font-size:12.5px}
.tgrp .hd .tot{color:var(--dim);font-variant-numeric:tabular-nums}
.trow{display:flex;align-items:center;gap:8px;font-size:12px;padding:2.5px 0}
.trow .sw{width:9px;height:9px;border-radius:2px;flex:none}
.trow .l{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.trow .v{width:78px;text-align:right;font-variant-numeric:tabular-nums}
.trow .pc{width:52px;text-align:right;color:var(--dim);font-variant-numeric:tabular-nums}
.note{color:var(--faint);font-size:11px;line-height:1.5;margin-top:10px}
.est{color:var(--faint);font-size:10px;border:1px solid var(--line);border-radius:4px;
  padding:0 4px;margin-left:5px;vertical-align:1px}
</style></head>
<body>
<div id="app"></div>
<script>
const $ = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const fmtTok = n => n >= 1e6 ? (n/1e6).toFixed(1)+"M" : n >= 1e3 ? (n/1e3).toFixed(1)+"k" : String(n||0);
const fmtInt = n => (n||0).toLocaleString();
const pct = x => Math.round((x||0)*100) + "%";
const dur = ms => ms == null ? "—" : ms >= 60000 ? Math.floor(ms/60000)+"m"+Math.round((ms%60000)/1000)+"s"
  : ms >= 1000 ? (ms/1000).toFixed(1)+" s" : ms+" ms";
const HS = {claude:"claude", copilot:"copilot", pi:"pi"};

let DATA = null;                 // {sessions, dashboard, scope}
let DET  = null;                 // {session, events, notes}
let SIDE = {q:"", harness:"all", closed:new Set(), off:false};
let VIEW = {tab:"trajectory", sel:-1, q:"", dur:false, colTurns:false, colCalls:false};
let ITAB = "summary";

async function api(path, body) {
  const opt = body ? {method:"POST", body:JSON.stringify(body),
                      headers:{"Content-Type":"application/json"}} : {};
  return (await fetch(path, opt)).json();
}

/* ---------------- sidebar ---------------- */
function ageOf(day) {
  const d = Date.parse((day || "") + "T00:00:00");
  if (isNaN(d)) return "";
  const n = Math.floor((Date.now() - d) / 86400000);
  return n <= 0 ? "today" : n + "d";
}

function sideRows() {
  const q = SIDE.q.toLowerCase();
  const rows = DATA.sessions.filter(s =>
    (SIDE.harness === "all" || s.harness === SIDE.harness) &&
    (!q || (s.title + " " + s.project + " " + s.harness).toLowerCase().includes(q)));
  const groups = new Map();
  for (const s of rows) {
    if (!groups.has(s.project_short)) groups.set(s.project_short, []);
    groups.get(s.project_short).push(s);
  }
  for (const list of groups.values())
    list.sort((a, b) => (a.day + a.date < b.day + b.date ? 1 : -1));
  return Array.from(groups.entries())
    .sort((a, b) => (a[1][0].day + a[1][0].date < b[1][0].day + b[1][0].date ? 1 : -1));
}

const HDOT = {claude:"#6f9bf5", copilot:"#43a86b", pi:"#a17ce0"};

function sidebarHTML() {
  if (SIDE.off) return "";
  const groups = DATA ? sideRows() : [];
  const cur = DET ? DET.session.path : "";
  const tree = groups.map(([proj, list]) => {
    const open = !SIDE.closed.has(proj);
    const kids = open ? list.map(s => `<div class="ses ${s.path===cur?"on":""}"
      data-p="${esc(s.path)}" title="${esc(s.title)}">
      <span class="dot" style="background:${HDOT[s.harness]||"#aab"}"></span>
      <span class="nm">${esc(s.title)}</span><span class="age">${ageOf(s.day)}</span></div>`).join("") : "";
    return `<div class="wsrow" data-ws="${esc(proj)}"><span class="car">${open?"▾":"▸"}</span>
      <span class="n">${esc(proj)}</span><span class="c">${list.length}</span></div>${kids}`;
  }).join("") || '<div class="empty">No sessions in scope.</div>';
  const pills = ["all", "claude", "copilot", "pi"].map(h =>
    `<div class="hp ${SIDE.harness===h?"on":""}" data-h="${h}">${h}</div>`).join("");
  return `<div class="side">
    <div class="brand"><span class="logo">session</span><span class="tag">ANALYTICS</span>
      <button class="fold" id="fold" title="Collapse sidebar">◧</button></div>
    <button class="newbtn" id="rescan">⟳ Rescan transcripts</button>
    <div class="sidehead"><span>Workspaces</span><div class="spacer"></div>
      <span class="ic" id="home" title="Overview">⌂</span></div>
    <div class="sidesearch"><input type="search" id="sq" placeholder="Search sessions…"
      value="${esc(SIDE.q)}"></div>
    <div class="hpills">${pills}</div>
    <div class="tree" id="tree">${tree}</div>
    <div class="sidefoot"><span>⚙</span><span>${DATA ? DATA.sessions.length : 0} sessions${
      DATA && DATA.scope && DATA.scope.cwd ? " · scoped" : ""}</span></div>
  </div>`;
}

function bindSidebar() {
  const sq = $("#sq");
  if (sq) sq.oninput = e => { SIDE.q = e.target.value; const p = e.target.selectionStart;
    render(); const el = $("#sq"); if (el) { el.focus(); el.setSelectionRange(p, p); } };
  $$(".hp").forEach(p => p.onclick = () => { SIDE.harness = p.dataset.h; render(); });
  $$(".wsrow").forEach(w => w.onclick = () => {
    const k = w.dataset.ws;
    SIDE.closed.has(k) ? SIDE.closed.delete(k) : SIDE.closed.add(k);
    render();
  });
  $$(".ses").forEach(s => s.onclick = () => { location.hash = "#/s/" + encodeURIComponent(s.dataset.p); });
  const r = $("#rescan");
  if (r) r.onclick = async () => { await api("/api/refresh", {}); DATA = await api("/api/sessions"); render(); };
  const h = $("#home");
  if (h) h.onclick = () => { location.hash = "#/"; };
  const f = $("#fold");
  if (f) f.onclick = () => { SIDE.off = true; render(); };
}

/* ---------------- overview (no session selected) ---------------- */
function bars(items, color, fmt) {
  const f = fmt || fmtInt;
  const mx = Math.max(1, ...items.map(i => i[1]));
  return items.map(([n, c]) => `<div class="rowbar"><div class="lbl" title="${esc(n)}">${esc(n)}</div>
    <div class="n">${f(c)}</div><div class="track">
    <div class="fill" style="width:${Math.round(100*c/mx)}%;background:${color||"var(--accent)"}"></div>
    </div></div>`).join("");
}

function heroHTML() {
  if (!DATA) return '<div class="empty">Scanning transcripts…</div>';
  const d = DATA.dashboard, rows = DATA.sessions;
  const a = rows.reduce((o, s) => {
    o.turns += s.turns; o.tools += s.tools; o.tok += s.total_tokens; o.err += s.tool_errors;
    o.cr += s.cache_read; o.cin += s.input_tokens + s.cache_creation; o.min += s.duration_min;
    if (s.goal === "achieved") o.ga++; else if (s.goal === "not_achieved") o.gn++;
    return o; }, {turns:0, tools:0, tok:0, err:0, cr:0, cin:0, min:0, ga:0, gn:0});
  const tiles = [
    ["Sessions", rows.length], ["User turns", fmtInt(a.turns)], ["Tool calls", fmtInt(a.tools)],
    ["Tokens", fmtTok(a.tok)], ["Cache hit", pct(a.cr/((a.cr+a.cin)||1))], ["Tool errors", a.err],
    ["Active", a.min >= 60 ? (a.min/60).toFixed(1)+" h" : Math.round(a.min)+" m"],
    ["GOAL ✓/✗", a.ga + " / " + a.gn],
  ].map(([k, v]) => `<div class="tile"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("");
  const pats = (d.error_patterns||[]).map(p => `<div class="rowbar"><div class="n">${p.count}×</div>
    <div class="lbl" style="flex:1;width:auto" title="${esc((p.example||{}).cmd||"")}">${esc(p.sig)}</div>
    </div>`).join("") || '<div class="dim">no tool errors in scope</div>';
  return `<div class="hero"><div class="heroin">
    <h1>Session Analytics<span class="badgepv">Preview</span></h1>
    <div class="p">Pick a session on the left to replay its trajectory step by step.</div>
    <div class="tiles">${tiles}</div>
    <div class="cols">
      <div class="card"><h2>Top tools</h2><div class="body">${bars(d.top_tools||[], "var(--tool)")}</div></div>
      <div class="card"><h2>Busiest projects</h2><div class="body">${bars(d.by_project||[], "var(--asst)")}</div></div>
      <div class="card"><h2>Tokens per day</h2><div class="body">${bars((d.tokens_by_day||[]).slice(-14), "var(--accent)", fmtTok)}</div></div>
      <div class="card"><h2>Recurring error patterns</h2><div class="body">${pats}</div></div>
    </div>
  </div></div>`;
}

/* ---------------- session view ---------------- */
const laneOf = k => k === "assistant" ? "Model" : k === "tool" ? "Tools" : "Input";
const kColor = k => k === "assistant" ? "#8b5cf6" : k === "tool" ? "#e08a3c"
  : k === "user" ? "#4e9be6" : k === "hook" ? "#43a86b" : "#c3c9d4";

function decorate(evs) {
  let req = 0;
  evs.forEach((e, i) => {
    if (e.kind === "assistant") req++;
    e.req = req; e.idx = i;
  });
}

function firstOfTurn() {
  const m = {};
  DET.events.forEach((e, i) => { if (e.turn && !(e.turn in m)) m[e.turn] = i; });
  return m;
}

function visibleEvents() {
  const q = VIEW.q.toLowerCase();
  const ft = firstOfTurn();
  return DET.events.map((e, i) => ({e, i})).filter(({e, i}) => {
    if (q && !((e.title + " " + e.preview + " " + e.text).toLowerCase().includes(q))) return false;
    if (VIEW.colTurns) return ft[e.turn] === i || (!e.turn && e.kind === "system");
    if (VIEW.colCalls) return e.kind === "user" || e.kind === "assistant";
    return true;
  });
}

function sessionHTML() {
  const s = DET.session;
  const tabs = ["chat", "trajectory", "metrics"].map(t =>
    `<div class="tab ${VIEW.tab===t?"on":""}" data-t="${t}">${t[0].toUpperCase()+t.slice(1)}</div>`).join("");
  const head = `<div class="hdr">
    ${SIDE.off ? '<button class="fold" id="unfold" title="Show sidebar">◧</button>' : ""}
    <span class="title" title="${esc(s.title)}">${esc(s.title)}</span>
    <span class="mode">${esc(s.harness)} · ${esc(s.project_short)} · ${esc(s.date)}</span>
    <div class="spacer"></div>
    <div class="tabs">${tabs}</div>
    <button class="btn" id="dl" style="margin-left:14px">Session log ⇩</button>
  </div>`;
  const body = VIEW.tab === "trajectory" ? trajectoryHTML()
             : VIEW.tab === "chat" ? chatHTML() : metricsHTML();
  return head + body + footHTML();
}

function trajectoryHTML() {
  const tg = (k, label, icon) =>
    `<div class="tg ${VIEW[k]?"on":""}" data-tg="${k}"><span>${icon}</span>${label}</div>`;
  return `<div class="tbar">
      ${tg("dur", "Duration", "◷")}${tg("colTurns", "Turns", "⊟")}${tg("colCalls", "Calls", "⊟")}
      <div class="spacer"></div>
      <input type="search" id="eq" placeholder="Search trajectory" value="${esc(VIEW.q)}">
    </div>
    <div class="map" id="map"></div>
    <div class="split" id="split"></div>`;
}

function footHTML() {
  const s = DET.session, evs = DET.events;
  const steps = evs.filter(e => e.kind === "tool" || e.kind === "assistant").length;
  const toolMs = evs.reduce((n, e) => n + (e.dur_ms || 0), 0);
  const t = DET.tokens, orows = (t && t.output.rows) || [];
  const think = orows.find(r => r.label === "Thinking");
  const cells = [
    `${s.turns} turns · ${steps} steps`,
    `Tool call ${dur(toolMs)}${s.tool_errors ? ` · <span class="bad">${s.tool_errors} failed</span>` : ""}`,
    `Wall ${Math.round(s.duration_min)} min`,
    think ? `Thinking ${think.pct}% of output` : `Output ${fmtTok(s.output_tokens)}`,
    `Cache hit ${pct(s.cache_ratio)}`,
    `Input ${fmtTok(s.input_tokens + s.cache_creation)} tok · Out ${fmtTok(s.output_tokens)} tok`,
    esc((s.models||[]).join(", ")) || "—",
  ];
  return `<div class="foot">${cells.map(c => `<span>${c}</span>`).join("")}</div>`;
}

function bindSession() {
  $$(".tab[data-t]").forEach(t => t.onclick = () => { VIEW.tab = t.dataset.t; render(); });
  const u = $("#unfold");
  if (u) u.onclick = () => { SIDE.off = false; render(); };
  const dl = $("#dl");
  if (dl) dl.onclick = () => {
    const blob = new Blob([JSON.stringify(DET, null, 2)], {type:"application/json"});
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = (DET.session.session_id || "session") + ".json";
    a.click(); URL.revokeObjectURL(a.href);
  };
  if (VIEW.tab === "trajectory") {
    $$(".tg").forEach(t => t.onclick = () => { VIEW[t.dataset.tg] = !VIEW[t.dataset.tg]; render(); });
    const eq = $("#eq");
    if (eq) eq.oninput = e => { VIEW.q = e.target.value; const p = e.target.selectionStart;
      render(); const el = $("#eq"); if (el) { el.focus(); el.setSelectionRange(p, p); } };
    renderMap();
    renderTrace();
  } else if (VIEW.tab === "metrics") bindMetrics();
}

function renderMap() {
  const lanes = {Input:[], Model:[], Tools:[]};
  visibleEvents().forEach(({e, i}) => lanes[laneOf(e.kind)].push({e, i}));
  const mx = Math.max(1, ...DET.events.map(e => e.dur_ms || 0));
  const w = e => VIEW.dur ? Math.max(4, Math.round(9 + 42 * (e.dur_ms || 0) / mx)) : 9;
  $("#map").innerHTML = Object.entries(lanes).map(([name, items]) =>
    `<div class="lane"><div class="name">${name}</div><div class="blocks">` +
    items.map(({e, i}) => `<div class="blk ${e.error?"err":""} ${VIEW.sel===i?"on":""}"
      data-i="${i}" style="background:${kColor(e.kind)};width:${w(e)}px"
      title="${esc(e.badge + " · " + e.title)}"></div>`).join("") +
    `</div></div>`).join("");
  $$(".blk").forEach(b => b.onclick = () => select(+b.dataset.i, true));
}

function renderTrace() {
  const ft = firstOfTurn();
  const rows = visibleEvents().map(({e, i}) => {
    const gut = ft[e.turn] === i ? `Turn ${e.turn}` : e.kind === "assistant" ? `#${e.req}` : "";
    const isMsg = e.kind === "user" || e.kind === "assistant" || e.kind === "context";
    const label = e.tool
      ? `<span class="nm">${esc(e.tool.name)}</span><span class="t">${esc(argsOf(e))}</span>`
      : `<span class="t">${esc(e.title)}</span>`;
    return `<div class="ev k-${e.kind} ${e.error?"err":""} ${isMsg?"prose":""}
      ${ft[e.turn]===i?"turnstart":""} ${VIEW.sel===i?"on":""}" data-i="${i}" id="ev${i}">
      <span class="gut">${esc(gut)}</span>
      <span class="badge">${esc(e.badge)}</span>${label}
      ${e.preview ? `<span class="arrow">→</span><span class="p">${esc(e.preview)}</span>` : ""}
    </div>`;
  }).join("");
  $("#split").innerHTML = `<div class="trace" id="trace">${rows ||
    '<div class="empty">Nothing matches this filter.</div>'}</div>
    <div class="insp" id="insp"></div>`;
  $$(".ev").forEach(r => r.onclick = () => select(+r.dataset.i));
  renderInspector();
}

function argsOf(e) {
  const a = (e.tool && e.tool.args) || "";
  return a.length > 220 ? a.slice(0, 219) + "…" : a;
}

function select(i, scroll) {
  VIEW.sel = i;
  $$(".ev").forEach(r => r.classList.toggle("on", +r.dataset.i === i));
  $$(".blk").forEach(b => b.classList.toggle("on", +b.dataset.i === i));
  if (scroll) { const el = $("#ev" + i); if (el) el.scrollIntoView({block:"center"}); }
  renderInspector();
}

/* ---------------- inspector ---------------- */
const ITABS = ["summary", "payload", "result", "schema", "timing", "raw"];

function inspSections(e) {
  const payload = e.tool ? e.tool.args : (e.text || e.title);
  const result  = e.tool ? e.tool.result : "";
  return {payload, result};
}

function schemaOf(e) {
  if (!e.tool) return "";
  let keys = [];
  try {
    const o = JSON.parse(e.tool.args);
    keys = Object.entries(o).map(([k, v]) =>
      `  ${k}: ${Array.isArray(v) ? "array" : v === null ? "null" : typeof v}`);
  } catch (_) { keys = []; }
  return `${e.tool.name}\n\nTranscripts do not record the tool's declared schema.\n` +
    (keys.length ? `Argument keys observed in this call:\n${keys.join("\n")}`
                 : "No structured arguments in this call.");
}

function renderInspector() {
  const box = $("#insp");
  if (!box) return;
  const e = VIEW.sel >= 0 ? DET.events[VIEW.sel] : null;
  if (!e) {
    box.innerHTML = `<div class="head"><span class="badge" style="background:var(--sysbg);color:var(--sys)">DETAILS</span>
      <div class="spacer"></div></div>
      <div class="empty">Click a tool row in the message flow to view its details</div>`;
    return;
  }
  const {payload, result} = inspSections(e);
  const t = e.tokens || {};
  const tot = (t.input||0)+(t.output||0)+(t.cache_read||0)+(t.cache_create||0);
  const sec = (h, body, cls) => (body && body.trim()) ?
    `<div class="sec"><h3><span class="car">▾</span>${h}</h3>
    <pre class="${cls||""}">${esc(body)}</pre></div>` : "";
  const kv = pairs => `<div class="kv">${pairs.filter(Boolean)
    .map(([k, v]) => `<div class="k">${esc(k)}</div><div>${v}</div>`).join("")}</div>`;

  const est = e.est || {};
  const parts = est.out_parts || {};
  const partTxt = Object.entries(parts).filter(([, v]) => v > 0)
    .map(([k, v]) => `${k.toLowerCase()} ${fmtInt(v)}`).join(" · ");
  const summary =
    kv([
      ["Hierarchy", `Turn ${e.turn||0} › Request #${e.req||0} › Step ${e.step||0}`],
      ["Status", e.error ? '<span class="bad">Failed</span>' : '<span class="ok">Completed</span>'],
      e.tool ? ["Tool", esc(e.tool.name)] : null,
      e.model ? ["Model", esc(e.model)] : null,
      tot ? ["Tokens", fmtInt(tot)] : null,
      est.out ? ["Generated", `${fmtInt(est.out)}<span class="est">est</span>${
        partTxt ? `<div class="dim" style="font-size:11px">${esc(partTxt)}</div>` : ""}`] : null,
      est.think ? ["  of it thinking", `${fmtInt(est.think)}<span class="est">est</span>`] : null,
      est.ctx ? ["Added to context", `${fmtInt(est.ctx)}<span class="est">est</span>`] : null,
    ]) +
    sec("Payload", (payload || "").slice(0, 1400)) +
    sec("Result", (result || "").slice(0, 1400)) +
    (e.tool ? sec("Schema", schemaOf(e).slice(0, 900), "plain") : "") +
    `<div class="sec"><h3><span class="car">▾</span>Timing</h3>${kv([
      ["Started", e.ts ? esc(new Date(e.ts).toLocaleString()) : "—"],
      ["Duration", dur(e.dur_ms)],
      ["Timing source", "Session timestamps"],
    ])}</div>`;

  const panes = {
    summary,
    payload: sec("Payload", payload) || '<div class="empty">No payload.</div>',
    result: sec("Result", result) + sec("Thinking", e.thinking) ||
            '<div class="empty">No result recorded.</div>',
    schema: sec("Schema", schemaOf(e), "plain") ||
            '<div class="empty">Schemas are not recorded for this event.</div>',
    timing: kv([
      ["Started", e.ts ? esc(new Date(e.ts).toLocaleString()) : "—"],
      ["Duration", dur(e.dur_ms)],
      ["Turn / step", `${e.turn||0} · ${e.step||0}`],
      ["Timing source", "Session timestamps"],
      tot ? ["Tokens", fmtInt(tot)] : null,
      t.output ? ["output", fmtInt(t.output)] : null,
      t.input ? ["input", fmtInt(t.input)] : null,
      t.cache_read ? ["cache read", fmtInt(t.cache_read)] : null,
      t.cache_create ? ["cache write", fmtInt(t.cache_create)] : null,
    ]),
    raw: sec("Raw event", e.raw) || '<div class="empty">No raw record.</div>',
  };
  box.innerHTML = `<div class="head">
      <span class="badge">${esc(e.badge)}</span>
      <span class="sub">Turn ${e.turn||0} · Step ${e.step||0}</span>
      <div class="spacer"></div><button class="x" id="ix">×</button></div>
    <div class="itabs">${ITABS.map(t =>
      `<div class="tab ${ITAB===t?"on":""}" data-it="${t}">${t[0].toUpperCase()+t.slice(1)}</div>`).join("")}</div>
    <div class="ibody">${panes[ITAB] || panes.summary}</div>`;
  $$("[data-it]").forEach(t => t.onclick = () => { ITAB = t.dataset.it; renderInspector(); });
  $("#ix").onclick = () => { VIEW.sel = -1; renderTrace(); renderMap(); };
}

/* ---------------- chat + metrics ---------------- */
function chatHTML() {
  const msgs = DET.events.filter(e => (e.kind === "user" || e.kind === "assistant") && e.text);
  return `<div class="pane"><div class="chat">${msgs.map(e =>
    `<div class="msg ${e.kind}"><div class="who">${esc(e.badge)}${
      e.model ? " · " + esc(e.model) : ""}</div><div class="txt">${esc(e.text)}</div></div>`).join("") ||
    '<div class="empty">No message text captured.</div>'}</div></div>`;
}

/* ---- token attribution ---- */
const TOKC = {
  "Thinking":"#7c4dd6", "Reply text":"#2563eb", "Tool calls":"#c2691b",
  "Tool results":"#c2691b", "Context injections":"#0f766e", "User prompts":"#2563eb",
  "Hook output":"#1a7f4b", "Model turns re-read":"#7c4dd6",
  "System prompt & tools":"#5b6472", "Not in the transcript":"#b9bfc9",
};
const tokc = l => TOKC[l] || "#8b93a7";

function tokGroup(title, total, rows, note) {
  if (!rows.length) return "";
  return `<div class="tgrp">
    <div class="hd"><b>${esc(title)}</b><span class="tot">${fmtInt(total)} tokens</span>
      ${note ? `<span class="dim" style="font-size:11px">${esc(note)}</span>` : ""}</div>
    <div class="sbar">${rows.map(r =>
      `<i style="width:${r.pct}%;background:${tokc(r.label)}" title="${esc(r.label)} ${r.pct}%"></i>`).join("")}</div>
    ${rows.map(r => `<div class="trow"><span class="sw" style="background:${tokc(r.label)}"></span>
      <span class="l">${esc(r.label)}</span><span class="v">${fmtInt(r.tokens)}</span>
      <span class="pc">${r.pct}%</span></div>`).join("")}
  </div>`;
}

function tokensHTML() {
  const t = DET.tokens;
  if (!t || (!t.output.total && !t.context.total))
    return `<div class="card"><h2>Where the tokens went</h2>
      <div class="body"><div class="dim">This harness records no token usage.</div></div></div>`;
  const r = t.reads;
  const tools = (t.by_tool || []).map(x => [x.label, x.tokens]);
  return `<div class="card"><h2>Where the tokens went</h2><div class="body">
    ${tokGroup("Generated (output)", t.output.total, t.output.rows,
               t.exact ? "" : "no usage recorded — sizes estimated from text")}
    ${tokGroup("Context ingested (unique)", t.context.total, t.context.rows)}
    <div class="tgrp"><div class="hd"><b>Context read per request</b>
      <span class="tot">${fmtTok(r.context_reads)} over ${r.requests} requests</span></div>
      <div class="trow"><span class="l">Same context re-sent each request</span>
        <span class="v">×${r.reread}</span><span class="pc"></span></div>
      <div class="trow"><span class="l">Served from cache</span>
        <span class="v">${fmtTok(r.cache_read)}</span>
        <span class="pc">${pct(r.cache_read/(r.context_reads||1))}</span></div>
    </div>
    ${tools.length ? `<div class="tgrp"><div class="hd"><b>Biggest context producers</b>
      <span class="tot">tool output only</span></div>${bars(tools, "var(--tool)", fmtInt)}</div>` : ""}
    <div class="note">Totals are exact. The slices are estimates: each response's real
    token count is divided by character share at ${t.ratio} chars/token, calibrated on
    this session's own responses. Thinking is the residual — Claude writes reasoning
    blocks with the text stripped, so it is measured as tokens billed minus tokens the
    visible text explains. "Not in the transcript" is context growth the log never
    spells out: tool schemas loaded mid-session, skill bodies, per-turn reminders.</div>
  </div></div>`;
}

function metricsHTML() {
  const s = DET.session;
  const files = f => f.length ? f.map(p => `<div>${esc(p)}</div>`).join("") : '<div class="dim">none</div>';
  const errs = (s.errors||[]).map(e => `<div class="sec"><div class="bad">✗ ${esc(e.tool)}: ${esc(e.cmd)}</div>
    <pre>${esc((e.msg||"").slice(0, 600))}</pre></div>`).join("") || '<div class="dim">none</div>';
  const notes = (DET.notes||[]).map(n => `<div class="rowbar"><div class="lbl" style="flex:1;width:auto">
    <span class="dim">[${esc((n.ts||"").slice(0,16))}]</span> ${esc(n.note)}</div></div>`).join("")
    || '<div class="dim">none yet</div>';
  return `<div class="pane"><div class="mwrap">
    <div class="tiles">${[
      ["Turns", s.turns], ["Assistant msgs", s.assistant_msgs], ["Tool calls", s.tools],
      ["Tool errors", s.tool_errors], ["Tokens", fmtTok(s.total_tokens)],
      ["Cache hit", pct(s.cache_ratio)], ["Duration", Math.round(s.duration_min)+" min"],
      ["GOAL", s.goal || "not recorded"],
    ].map(([k, v]) => `<div class="tile"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("")}</div>
    <div style="margin-top:12px">${tokensHTML()}</div>
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
  </div></div>`;
}

function bindMetrics() {
  const btn = $("#addnote");
  if (!btn) return;
  btn.onclick = async () => {
    const v = $("#note").value.trim();
    if (!v) return;
    const r = await api("/api/note", {path: DET.session.path, note: v});
    if (r.note) { DET.notes.unshift(r.note); render(); }
  };
}

/* ---------------- shell + routing ---------------- */
function render() {
  $("#app").innerHTML = sidebarHTML() +
    `<div class="main">${DET ? sessionHTML() : heroHTML()}</div>`;
  bindSidebar();
  if (DET) bindSession();
}

async function loadIndex() {
  $("#app").innerHTML = '<div class="empty">Scanning transcripts…</div>';
  DATA = await api("/api/sessions");
}

async function route() {
  if (!DATA) await loadIndex();
  const h = location.hash || "#/";
  if (h.startsWith("#/s/")) {
    const path = decodeURIComponent(h.slice(4));
    if (!DET || DET.session.path !== path) {
      DET = await api("/api/session?path=" + encodeURIComponent(path));
      if (DET.error) { DET = null; location.hash = "#/"; return; }
      decorate(DET.events);
      VIEW = {tab:"trajectory", sel:-1, q:"", dur:false, colTurns:false, colCalls:false};
    }
  } else DET = null;
  render();
}

window.addEventListener("hashchange", route);
window.addEventListener("keydown", e => {
  if (!DET || VIEW.tab !== "trajectory" || /input/i.test(e.target.tagName)) return;
  const vis = visibleEvents().map(v => v.i);
  if (!vis.length) return;
  const at = vis.indexOf(VIEW.sel);
  if (e.key === "j" || e.key === "ArrowDown") {
    select(vis[Math.min(at + 1, vis.length - 1)] ?? vis[0], true); e.preventDefault(); }
  if (e.key === "k" || e.key === "ArrowUp") {
    select(vis[Math.max(at - 1, 0)] ?? vis[0], true); e.preventDefault(); }
  if (e.key === "Escape") location.hash = "#/";
});
route();
</script></body></html>
"""


def _load_analytics():
    """Import session-analytics.py from next to this file (hyphens block a
    normal import), so `python3 session-web.py` works standalone."""
    import importlib.util
    import sys
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "session-analytics.py")
    spec = importlib.util.spec_from_file_location("session_analytics", path)
    mod = importlib.util.module_from_spec(spec)
    # @dataclass resolves its own module through sys.modules, so register the
    # module before executing it or every dataclass in there raises.
    sys.modules["session_analytics"] = mod
    spec.loader.exec_module(mod)
    return mod


if __name__ == "__main__":
    raise SystemExit(serve(_load_analytics()))

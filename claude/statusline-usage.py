#!/usr/bin/env python3
"""Claude Code status line — Variant A (dense single-row).

Renders one compact line at the bottom of the Claude Code CLI, matching the
exact numbers shown by the `/usage` command:

    claude-opus-4-8 │ ctx ███░░░░░ 63k/200k │ 5h ██████░░ 72% 1h12m │ dir workspace

Data sources (all read-only):
  * model   -> stdin JSON  (model.display_name)                      [from CLI]
  * ctx     -> active transcript's last usage block / context window [local, exact]
  * 5h / wk -> GET /api/oauth/usage  (five_hour / seven_day .utilization)
               — the same authenticated endpoint `/usage` calls.

The /usage figures are NOT persisted by Claude Code; they are fetched live from
the API. To keep the (frequently re-run) status line fast we cache the response
for USAGE_TTL seconds and refresh in a detached background process, so a render
never blocks on the network (except the very first call when no cache exists).

Contract: this script must ALWAYS exit 0 and print exactly one line; any failure
degrades gracefully (stale cache, then an "unavailable" marker) rather than
breaking the CLI footer.

Usage: `statusline-usage.py`            -> render a status line (reads stdin JSON)
       `statusline-usage.py --refresh`  -> refresh the usage cache only (internal)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# ----------------------------------------------------------------------------
# Configuration — override via environment variables.
# ----------------------------------------------------------------------------
CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
CREDENTIALS = CLAUDE_DIR / ".credentials.json"
USAGE_CACHE = CLAUDE_DIR / ".statusline-usage-cache.json"

CONTEXT_WINDOW = int(os.environ.get("CLAUDE_CONTEXT_WINDOW", 200_000))
USAGE_TTL = int(os.environ.get("CLAUDE_USAGE_TTL", 5))    # seconds before refresh
HTTP_TIMEOUT = int(os.environ.get("CLAUDE_USAGE_HTTP_TIMEOUT", 5))

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"

BAR_WIDTH = 8
TAIL_BYTES = 256 * 1024  # bytes read from the tail of the active transcript

# Plain style: no colors, default terminal foreground everywhere.
C_RESET = ""
C_CORAL = ""
C_OK = ""
C_WARN = ""
C_DANGER = ""
C_MUTED = ""
C_TRACK = ""

FILL_CHAR = "█"
EMPTY_CHAR = "░"
SEP = f"{C_MUTED}│{C_RESET}"


# ----------------------------------------------------------------------------
# Formatting helpers
# ----------------------------------------------------------------------------
def fmt_tokens(n: int) -> str:
    """Human-readable token count: 940 -> 940, 124300 -> 124k, 2_500_000 -> 2.5M."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".replace(".0M", "M")
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def usage_color(pct: float) -> str:
    """Traffic-light color by utilisation: <60 ok, <85 warn, else danger."""
    if pct < 60:
        return C_OK
    if pct < 85:
        return C_WARN
    return C_DANGER


def render_bar(pct: float, fill_color: str) -> str:
    """A fixed-width unicode bar coloured by `fill_color`, clamped to [0, 100]."""
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / 100 * BAR_WIDTH)
    return (
        f"{fill_color}{FILL_CHAR * filled}{C_RESET}"
        f"{C_TRACK}{EMPTY_CHAR * (BAR_WIDTH - filled)}{C_RESET}"
    )


def segment(label: str, pct: float, value: str, fill_color: str) -> str:
    """One `label bar value` group; value is shown in the same color as the bar."""
    return f"{C_MUTED}{label}{C_RESET} {render_bar(pct, fill_color)} {fill_color}{value}{C_RESET}"


def unavailable(label: str) -> str:
    """Placeholder when the usage API can't be reached (no fake number shown)."""
    return f"{C_MUTED}{label} {EMPTY_CHAR * BAR_WIDTH} —{C_RESET}"


def reset_countdown(iso: str | None) -> str:
    """Compact 'time until reset' from an ISO-8601 instant, e.g. '1h12m' / '4m'.
    Shown as plain text (no ⟳ glyph, which overlaps the time in some fonts)."""
    if not iso:
        return ""
    try:
        when = datetime.fromisoformat(iso)
        secs = int((when - datetime.now(when.tzinfo)).total_seconds())
    except (ValueError, TypeError):
        return ""
    if secs <= 0:
        return "now"
    h, m = divmod(secs // 60, 60)
    d, h = divmod(h, 24)
    if d:
        return f"{d}d{h}h"
    return f"{h}h{m:02d}m" if h else f"{m}m"


# ----------------------------------------------------------------------------
# Context window (local, exact) — from the active transcript's last usage block.
# ----------------------------------------------------------------------------
def context_tokens(transcript_path: str | None) -> int:
    if not transcript_path:
        return 0
    try:
        with open(transcript_path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - TAIL_BYTES))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return 0
    for line in reversed(lines):
        usage = _usage_of(line)
        if usage is not None:
            return (
                usage.get("input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
            )
    return 0


def _usage_of(line: str) -> dict | None:
    try:
        usage = json.loads(line).get("message", {}).get("usage")
    except (json.JSONDecodeError, ValueError, AttributeError):
        return None
    return usage if isinstance(usage, dict) else None


# ----------------------------------------------------------------------------
# Real usage (5h / weekly) — same endpoint `/usage` uses, cached + async refresh.
# ----------------------------------------------------------------------------
def _access_token() -> str | None:
    try:
        data = json.loads(CREDENTIALS.read_text())
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    oauth = data.get("claudeAiOauth") if isinstance(data.get("claudeAiOauth"), dict) else data
    return oauth.get("accessToken")


def fetch_usage() -> dict | None:
    """Live GET of the usage endpoint. Returns parsed JSON or None on any failure
    (expired token, offline, endpoint change) so callers can fall back."""
    token = _access_token()
    if not token:
        return None
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": OAUTH_BETA,
            "User-Agent": "claude-code-statusline",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return None


def _write_cache(data: dict) -> None:
    """Atomically persist the usage payload with owner-only permissions."""
    tmp = USAGE_CACHE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(data))
        os.chmod(tmp, 0o600)
        os.replace(tmp, USAGE_CACHE)
    except OSError:
        pass


def refresh_cache() -> dict | None:
    data = fetch_usage()
    if data is not None:
        _write_cache(data)
    return data


def _spawn_background_refresh() -> None:
    """Fire-and-forget refresh so renders never block on the network."""
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--refresh"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        pass


def get_usage() -> dict | None:
    """Return usage data: fresh cache if young; stale cache + async refresh if
    aged; a one-time blocking fetch only when no cache exists yet."""
    try:
        age = time.time() - USAGE_CACHE.stat().st_mtime
        cached = json.loads(USAGE_CACHE.read_text())
    except (OSError, json.JSONDecodeError, ValueError):
        return refresh_cache()  # first run / corrupt cache: fetch synchronously
    if age > USAGE_TTL:
        os.utime(USAGE_CACHE, None)   # debounce: reset age so we spawn at most once/TTL
        _spawn_background_refresh()
    return cached


# ----------------------------------------------------------------------------
# Render
# ----------------------------------------------------------------------------
def _window_segment(label: str, window: dict | None) -> str:
    """Build a 5h/weekly segment from a {utilization, resets_at} window block."""
    if not isinstance(window, dict) or window.get("utilization") is None:
        return unavailable(label)
    pct = float(window["utilization"])
    countdown = reset_countdown(window.get("resets_at"))
    value = f"{pct:.0f}%" + (f" {countdown}" if countdown else "")
    return segment(label, pct, value, usage_color(pct))


def cwd_folder(payload: dict) -> str:
    """Basename of the current working directory (falls back to os.getcwd())."""
    cwd = payload.get("cwd") or os.getcwd()
    return os.path.basename(cwd.rstrip(os.sep)) or cwd


def effort_label(payload: dict) -> str:
    """Reasoning effort level (low/medium/high/xhigh/max); "" if the model has none."""
    effort = payload.get("effort")
    if not isinstance(effort, dict) or not effort.get("level"):
        return ""
    return str(effort["level"])


def build_status(payload: dict) -> str:
    model = (payload.get("model") or {}).get("display_name") or "claude"

    ctx = context_tokens(payload.get("transcript_path"))
    ctx_pct = ctx / CONTEXT_WINDOW * 100 if CONTEXT_WINDOW else 0
    ctx_seg = segment("ctx", ctx_pct, f"{fmt_tokens(ctx)}/{fmt_tokens(CONTEXT_WINDOW)}", C_CORAL)

    usage = get_usage() or {}
    h5_seg = _window_segment("5h", usage.get("five_hour"))

    dir_seg = f"{C_MUTED}dir {C_RESET}{C_CORAL}{cwd_folder(payload)}{C_RESET}"
    effort = effort_label(payload)
    if effort:
        dir_seg += f" {C_MUTED}·{C_RESET}{C_CORAL}{effort}{C_RESET}"

    return f" {C_CORAL}{model}{C_RESET} {SEP} {ctx_seg} {SEP} {h5_seg} {SEP} {dir_seg}"


def main() -> None:
    if "--refresh" in sys.argv[1:]:
        refresh_cache()
        return
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (json.JSONDecodeError, ValueError):
        payload = {}
    try:
        sys.stdout.write(build_status(payload))
    except Exception:  # noqa: BLE001 — the footer must never break the CLI
        model = (payload.get("model") or {}).get("display_name") or "claude"
        sys.stdout.write(f" {C_CORAL}{model}{C_RESET}")


if __name__ == "__main__":
    main()

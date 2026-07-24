#!/usr/bin/env python3
"""Unit tests for session-analytics.py pure logic (parse / aggregate / notes).
Run: python3 -m unittest claude/test_session_analytics.py  (from repo root)
or:  python3 claude/test_session_analytics.py
"""
import importlib.util
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "session_analytics", os.path.join(_HERE, "session-analytics.py")
)
sa = importlib.util.module_from_spec(_spec)
# Register before exec so dataclass string annotations resolve their module.
sys.modules["session_analytics"] = sa
_spec.loader.exec_module(sa)


def _assistant(usage=None, tools=(), text=None, model="claude-opus-4-8"):
    content = []
    if text is not None:
        content.append({"type": "text", "text": text})
    for t in tools:
        content.append({"type": "tool_use", "name": t})
    return {
        "type": "assistant",
        "timestamp": "2026-07-24T10:00:00.000Z",
        "message": {"model": model, "usage": usage or {}, "content": content},
    }


class ParseSessionTest(unittest.TestCase):
    def test_full_session(self):
        rows = [
            {"type": "ai-title", "aiTitle": "Fix the widget"},
            {"type": "user", "timestamp": "2026-07-24T10:00:00.000Z",
             "cwd": "/home/mohan/REPO/proj", "message": {"content": "do the thing"}},
            {"type": "user", "message": {"content": "<local-command>noise"}},
            _assistant(
                usage={"input_tokens": 10, "output_tokens": 100,
                       "cache_read_input_tokens": 900,
                       "cache_creation_input_tokens": 90},
                tools=["Bash", "Read", "Bash"],
                text="working. GOAL_CHECK: ACHIEVED done",
            ),
            {"type": "attachment", "attachment": {
                "type": "hook_success", "hookEvent": "SessionStart",
                "hookName": "startup", "exitCode": 0}},
            {"type": "user", "timestamp": "2026-07-24T10:05:00.000Z",
             "message": {"content": [
                 {"type": "tool_result", "is_error": True, "content": "boom"}]}},
        ]
        s = sa.parse_session(rows, path="/x/abc123.jsonl")

        self.assertEqual(s.session_id, "abc123")
        self.assertEqual(s.title, "Fix the widget")
        self.assertEqual(s.project, "/home/mohan/REPO/proj")
        self.assertEqual(s.project_short, "proj")
        self.assertEqual(s.user_turns, 1)  # 1 real prompt; local-cmd + tool_result skipped
        self.assertEqual(s.tools["Bash"], 2)
        self.assertEqual(s.tools["Read"], 1)
        self.assertEqual(s.total_tools, 3)
        self.assertEqual(s.input_tokens, 10)
        self.assertEqual(s.output_tokens, 100)
        self.assertEqual(s.cache_read, 900)
        self.assertEqual(s.total_tokens, 1100)
        self.assertEqual(s.tool_errors, 1)
        self.assertEqual(s.hook_fires["SessionStart/startup"], 1)
        self.assertEqual(s.hook_errors, 0)
        self.assertEqual(s.goal, "achieved")
        self.assertAlmostEqual(s.duration_min, 5.0, places=1)
        self.assertIn("claude-opus-4-8", s.models)
        # cache_ratio = 900 / (900 + 10 + 90) = 0.9
        self.assertAlmostEqual(s.cache_ratio, 0.9, places=3)

    def test_goal_not_achieved_and_hook_error(self):
        rows = [
            _assistant(text="GOAL_CHECK: NOT_ACHIEVED — blocked"),
            {"type": "attachment", "attachment": {
                "type": "hook_success", "hookEvent": "PreToolUse",
                "hookName": "guard", "exitCode": 1}},
        ]
        s = sa.parse_session(rows, path="/x/z.jsonl")
        self.assertEqual(s.goal, "not_achieved")
        self.assertEqual(s.hook_errors, 1)

    def test_no_goal_marker(self):
        s = sa.parse_session([_assistant(text="just chatting")], path="/x/z.jsonl")
        self.assertEqual(s.goal, "")

    def test_error_details_attributed_to_tool(self):
        rows = [
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": "t1", "name": "Read",
                 "input": {"file_path": "/repo/dir"}}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t1", "is_error": True,
                 "content": "EISDIR: illegal operation on a directory, "
                            "read '/repo/dir'"}]}},
        ]
        s = sa.parse_session(rows, path="/x/z.jsonl")
        self.assertEqual(s.tool_errors, 1)
        self.assertEqual(len(s.errors), 1)
        e = s.errors[0]
        self.assertEqual(e["tool"], "Read")
        self.assertEqual(e["cmd"], "/repo/dir")
        self.assertIn("EISDIR", e["msg"])
        # signature collapses the quoted path so repeats group together
        self.assertIn("Read: EISDIR", e["sig"])
        self.assertNotIn("/repo/dir", e["sig"])

    def test_error_signature_groups_variants(self):
        s1 = sa._error_signature("Read", "EISDIR: ... read '/a/one'")
        s2 = sa._error_signature("Read", "EISDIR: ... read '/b/two/three'")
        self.assertEqual(s1, s2)

    def test_error_signature_whitespace_only(self):
        # Truthy but strips to empty: splitlines() is [], must not IndexError.
        self.assertEqual(sa._error_signature("Bash", "   "), "Bash:")
        self.assertEqual(sa._error_signature("Bash", "\n"), "Bash:")

    def test_prompts_and_file_ops(self):
        rows = [
            {"type": "user", "message": {"content": "first ask"}},
            {"type": "user", "message": {"content": "<local-command>skip"}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Write",
                 "input": {"file_path": "/p/new.py"}},
                {"type": "tool_use", "name": "Edit",
                 "input": {"file_path": "/p/new.py"}},   # created then edited
                {"type": "tool_use", "name": "Edit",
                 "input": {"file_path": "/p/old.py"}},    # pre-existing edit
                {"type": "tool_use", "name": "Bash",
                 "input": {"command": "rm -f /p/gone.txt && echo done"}},
            ]}},
            {"type": "user", "message": {"content": "second ask"}},
        ]
        s = sa.parse_session(rows, path="/x/z.jsonl")
        self.assertEqual(s.prompts, ["first ask", "second ask"])
        self.assertEqual(s.n_added, 1)                    # new.py
        self.assertEqual(s.files_added, {"/p/new.py"})
        self.assertEqual(s.n_edited, 1)                   # old.py only (new.py is added)
        self.assertEqual(s.files_edited, {"/p/old.py"})
        self.assertEqual(s.n_removed, 1)
        self.assertEqual(s.files_removed, {"/p/gone.txt"})

    def test_rm_targets_parsing(self):
        self.assertEqual(
            sa._rm_targets("rm -rf a.txt b.txt"), ["a.txt", "b.txt"])
        self.assertEqual(
            sa._rm_targets("cd /x && rm foo.py"), ["foo.py"])
        self.assertEqual(sa._rm_targets("echo hi"), [])


class AggregateTest(unittest.TestCase):
    def _mk(self, **kw):
        s = sa.Session(**kw)
        return s

    def test_totals_and_rates(self):
        a_sess = sa.Session(project="/a/one", user_turns=3, tool_errors=2,
                            goal="achieved")
        a_sess.tools.update({"Bash": 5, "Read": 2})
        a_sess.input_tokens, a_sess.cache_read = 100, 900
        b_sess = sa.Session(project="/a/two", user_turns=1, goal="not_achieved")
        b_sess.tools.update({"Bash": 1})
        c_sess = sa.Session(project="/a/one", user_turns=2, goal="")

        agg = sa.aggregate([a_sess, b_sess, c_sess])
        self.assertEqual(agg.n_sessions, 3)
        self.assertEqual(agg.turns, 6)
        self.assertEqual(agg.tool_calls, 8)
        self.assertEqual(agg.top_tools["Bash"], 6)
        self.assertEqual(agg.by_project["one"], 2)
        self.assertEqual(agg.errors_by_project["one"], 2)
        self.assertEqual(agg.goal_achieved, 1)
        self.assertEqual(agg.goal_not, 1)
        self.assertEqual(agg.goal_none, 1)
        # 1 achieved of 2 scored
        self.assertAlmostEqual(agg.goal_rate, 0.5, places=3)
        self.assertAlmostEqual(agg.avg_turns, 2.0, places=3)
        self.assertAlmostEqual(agg.cache_ratio, 0.9, places=3)

    def test_empty(self):
        agg = sa.aggregate([])
        self.assertEqual(agg.n_sessions, 0)
        self.assertEqual(agg.goal_rate, 0.0)
        self.assertEqual(agg.avg_turns, 0.0)
        self.assertEqual(agg.output_input_ratio, 0.0)
        self.assertEqual(agg.tool_error_rate, 0.0)
        self.assertEqual(dict(agg.tokens_by_day), {})

    def test_indicator_ratios(self):
        s = sa.Session(input_tokens=200, output_tokens=100, cache_creation=0)
        s.tools.update({"Bash": 8})   # 8 tool calls
        s.tool_errors = 2
        agg = sa.aggregate([s])
        # output / (input + cache_creation) = 100 / 200
        self.assertAlmostEqual(agg.output_input_ratio, 0.5, places=3)
        # 2 errors of 8 tool calls
        self.assertAlmostEqual(agg.tool_error_rate, 0.25, places=3)

    def test_tokens_by_day(self):
        from datetime import datetime, timezone
        d1 = datetime(2026, 7, 20, 9, 0, tzinfo=timezone.utc)
        d2 = datetime(2026, 7, 21, 9, 0, tzinfo=timezone.utc)
        a1 = sa.Session(start=d1, input_tokens=100)         # 100 tokens on 07-20
        a2 = sa.Session(start=d1, output_tokens=50)         # +50 same day
        b1 = sa.Session(start=d2, cache_read=900)           # 900 on 07-21
        agg = sa.aggregate([a1, a2, b1])
        self.assertEqual(agg.tokens_by_day["2026-07-20"], 150)
        self.assertEqual(agg.tokens_by_day["2026-07-21"], 900)
        # a session with no timestamp contributes no day bucket
        agg2 = sa.aggregate([sa.Session(input_tokens=10)])
        self.assertEqual(dict(agg2.tokens_by_day), {})

    def test_error_patterns_aggregated(self):
        a_sess = sa.Session(project="/a/one", tool_errors=2)
        a_sess.errors = [
            {"tool": "Read", "cmd": "/x", "msg": "EISDIR '/x'",
             "sig": "Read: EISDIR '…'"},
            {"tool": "Bash", "cmd": "npm t", "msg": "exit 1",
             "sig": "Bash: exit N"},
        ]
        b_sess = sa.Session(project="/a/two", tool_errors=1)
        b_sess.errors = [
            {"tool": "Read", "cmd": "/y", "msg": "EISDIR '/y'",
             "sig": "Read: EISDIR '…'"},
        ]
        agg = sa.aggregate([a_sess, b_sess])
        self.assertEqual(agg.errors_by_tool["Read"], 2)
        self.assertEqual(agg.errors_by_tool["Bash"], 1)
        self.assertEqual(agg.error_patterns["Read: EISDIR '…'"], 2)
        self.assertIn("Read: EISDIR '…'", agg.error_examples)


class CopilotParseTest(unittest.TestCase):
    def test_copilot_session(self):
        rows = [
            {"type": "session.start", "timestamp": "2026-07-15T17:49:33.000Z",
             "data": {"sessionId": "cop1",
                      "context": {"cwd": "/home/mohan/REPO/proj"},
                      "startTime": "2026-07-15T17:49:33.000Z"}},
            {"type": "session.auto_mode_resolved", "data": {"chosenModel": "claude-haiku-4.5"}},
            {"type": "user.message", "timestamp": "2026-07-15T17:49:35.000Z",
             "data": {"content": "do the task"}},
            {"type": "assistant.message", "timestamp": "2026-07-15T17:49:36.000Z",
             "data": {"model": "claude-haiku-4.5", "content": "on it. GOAL_CHECK: ACHIEVED",
                      "toolRequests": [
                          {"toolCallId": "t1", "name": "view", "arguments": {"path": "/p/a.txt"}},
                          {"toolCallId": "t2", "name": "edit", "arguments": {"path": "/p/a.txt"}}]}},
            {"type": "tool.execution_complete", "timestamp": "2026-07-15T17:49:37.000Z",
             "data": {"toolCallId": "t2", "success": False,
                      "error": {"message": "No match found"}}},
            {"type": "hook.end", "data": {"hookType": "sessionStart", "exitCode": 0}},
        ]
        s = sa.parse_copilot_session(rows, path="/x/events.jsonl")
        self.assertEqual(s.harness, "copilot")
        self.assertEqual(s.session_id, "cop1")
        self.assertEqual(s.project, "/home/mohan/REPO/proj")
        self.assertEqual(s.user_turns, 1)
        self.assertEqual(s.prompts, ["do the task"])
        self.assertEqual(s.tools["view"], 1)
        self.assertEqual(s.tools["edit"], 1)
        self.assertEqual(s.goal, "achieved")
        self.assertEqual(s.tool_errors, 1)
        self.assertEqual(s.errors[0]["tool"], "edit")  # attributed via toolCallId
        self.assertIn("No match found", s.errors[0]["msg"])
        self.assertEqual(s.files_edited, {"/p/a.txt"})
        self.assertIn("claude-haiku-4.5", s.models)
        self.assertEqual(s.total_tokens, 0)  # copilot records no usage
        self.assertEqual(s.hook_fires["sessionStart"], 1)


class PiParseTest(unittest.TestCase):
    def test_pi_session(self):
        rows = [
            {"type": "session", "timestamp": "2026-07-04T20:17:54.000Z",
             "id": "pi1", "cwd": "/home/mohan"},
            {"type": "model_change", "modelId": "deepseek-v4-flash"},
            {"type": "message", "timestamp": "2026-07-04T20:18:24.000Z",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "run the hooks"}]}},
            {"type": "message", "timestamp": "2026-07-04T20:18:30.000Z",
             "message": {"role": "assistant",
                         "usage": {"input": 1583, "output": 97,
                                   "cacheRead": 512, "cacheWrite": 8},
                         "content": [
                             {"type": "thinking", "text": "hmm"},
                             {"type": "text", "text": "done. GOAL_CHECK: ACHIEVED"},
                             {"type": "toolCall", "name": "bash",
                              "arguments": {"command": "rm /p/gone.txt"}}]}},
            {"type": "message", "timestamp": "2026-07-04T20:18:31.000Z",
             "message": {"role": "toolResult", "toolName": "bash", "isError": True,
                         "content": [{"type": "text", "text": "boom exit 1"}]}},
        ]
        s = sa.parse_pi_session(rows, path="/x/ts_pi1.jsonl")
        self.assertEqual(s.harness, "pi")
        self.assertEqual(s.session_id, "pi1")
        self.assertEqual(s.project, "/home/mohan")
        self.assertEqual(s.user_turns, 1)
        self.assertEqual(s.prompts, ["run the hooks"])
        self.assertEqual(s.tools["bash"], 1)
        self.assertEqual(s.goal, "achieved")
        self.assertEqual(s.input_tokens, 1583)
        self.assertEqual(s.output_tokens, 97)
        self.assertEqual(s.cache_read, 512)
        self.assertEqual(s.cache_creation, 8)
        self.assertEqual(s.total_tokens, 1583 + 97 + 512 + 8)
        self.assertEqual(s.tool_errors, 1)
        self.assertEqual(s.errors[0]["tool"], "bash")
        self.assertEqual(s.files_removed, {"/p/gone.txt"})
        self.assertIn("deepseek-v4-flash", s.models)

    def test_by_harness_aggregation(self):
        a = sa.Session(harness="claude", user_turns=1)
        b = sa.Session(harness="copilot", user_turns=1)
        c = sa.Session(harness="pi", user_turns=1)
        d = sa.Session(harness="claude", user_turns=1)
        agg = sa.aggregate([a, b, c, d])
        self.assertEqual(agg.by_harness["claude"], 2)
        self.assertEqual(agg.by_harness["copilot"], 1)
        self.assertEqual(agg.by_harness["pi"], 1)


class PickerFilterTest(unittest.TestCase):
    """App.__init__ touches no curses, so the picker's harness scoping is
    testable headlessly (stdscr=None)."""

    def _app(self):
        sessions = [
            sa.Session(harness="claude", user_turns=1, title="c1"),
            sa.Session(harness="claude", user_turns=1, title="c2"),
            sa.Session(harness="pi", user_turns=1, title="p1"),
            sa.Session(harness="copilot", user_turns=1, title="x1"),
        ]
        return sa.App(None, sessions)

    def test_default_all_agents(self):
        app = self._app()
        self.assertIsNone(app.harness_sel)
        self.assertEqual(len(app.sessions), 4)  # all agents
        self.assertEqual(app.view, "picker")    # opens on the picker

    def test_apply_scopes_to_selected_harness(self):
        app = self._app()
        app.harness_sel = "claude"
        app._apply()
        self.assertEqual(len(app.sessions), 2)
        self.assertTrue(all(s.harness == "claude" for s in app.sessions))
        app.harness_sel = "pi"
        app._apply()
        self.assertEqual([s.title for s in app.sessions], ["p1"])

    def test_picker_cursor_tracks_selection(self):
        app = self._app()
        app.harness_sel = "copilot"
        self.assertEqual(
            app.picker_opts[app._picker_cursor_for_sel()][0], "copilot")
        app.harness_sel = None
        self.assertEqual(
            app.picker_opts[app._picker_cursor_for_sel()][0], "all")


class SortTest(unittest.TestCase):
    def test_sort_by_turns(self):
        s1 = sa.Session(user_turns=1)
        s2 = sa.Session(user_turns=9)
        name, out = sa.sort_sessions([s1, s2], 1)  # index 1 == "turns"
        self.assertEqual(name, "turns")
        self.assertEqual(out[0].user_turns, 9)


class NotesTest(unittest.TestCase):
    def test_save_load_roundtrip_and_filter(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "notes.jsonl")
            sa.save_note("sid1", "/p/one", "T1", "first note", path=path)
            sa.save_note("sid2", "/p/two", "T2", "second note", path=path)
            notes = sa.load_notes(path=path)
            self.assertEqual(len(notes), 2)
            self.assertEqual(
                {n["session_id"] for n in notes}, {"sid1", "sid2"})
            self.assertEqual(
                sa.notes_for("sid1", notes)[0]["note"], "first note")

    def test_load_missing_file(self):
        self.assertEqual(sa.load_notes(path="/nonexistent/xyz.jsonl"), [])


class ReportTest(unittest.TestCase):
    def test_render_report_smoke(self):
        s = sa.Session(project="/a/one", user_turns=2, goal="achieved")
        s.tools.update({"Bash": 3})
        out = sa.render_report([s])
        self.assertIn("Session Analytics", out)
        self.assertIn("Bash", out)


class _FakeCurses:
    """Minimal curses stand-in so Theme.init is testable without a terminal."""
    A_REVERSE, A_BOLD, A_UNDERLINE, A_DIM = 1, 2, 4, 8
    (COLOR_BLACK, COLOR_RED, COLOR_GREEN, COLOR_YELLOW,
     COLOR_BLUE, COLOR_MAGENTA, COLOR_CYAN, COLOR_WHITE) = range(8)

    def __init__(self):
        self.pairs = {}

    def has_colors(self):
        return True

    def start_color(self):
        pass

    def use_default_colors(self):
        pass

    def init_pair(self, pid, fg, bg):
        self.pairs[pid] = (fg, bg)

    def color_pair(self, pid):
        return pid << 8  # non-overlapping with the attr bits above


class ThemeTest(unittest.TestCase):
    def test_all_themes_registered(self):
        self.assertEqual(set(sa.THEME_NAMES), set(sa._THEME_SPECS))

    def test_mono_uses_no_color_pairs(self):
        fc = _FakeCurses()
        t = sa.Theme("mono")
        t.init(fc)
        self.assertEqual(fc.pairs, {})  # mono allocates no color pairs
        # title still carries reverse+bold attrs
        self.assertTrue(t.a("title") & fc.A_REVERSE)
        self.assertTrue(t.a("title") & fc.A_BOLD)

    def test_color_theme_allocates_pairs_and_attrs(self):
        fc = _FakeCurses()
        t = sa.Theme("ocean")
        t.init(fc)
        self.assertTrue(fc.pairs)  # colored roles allocated pairs
        # 'ok' should be green, bold, and carry a color pair bit
        ok = t.a("ok")
        self.assertTrue(ok & fc.A_BOLD)
        self.assertTrue(ok >= (1 << 8))

    def test_unknown_theme_falls_back(self):
        t = sa.Theme("does-not-exist")
        self.assertEqual(t.name, sa.THEME_NAMES[0])

    def test_a_before_init_is_safe(self):
        self.assertEqual(sa.Theme("ocean").a("title"), 0)


class ConfigTest(unittest.TestCase):
    def test_config_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cfg.json")
            self.assertEqual(sa.load_config(path), {})
            sa.save_config({"theme": "matrix"}, path)
            self.assertEqual(sa.load_config(path), {"theme": "matrix"})


if __name__ == "__main__":
    unittest.main(verbosity=2)

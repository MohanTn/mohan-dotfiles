#!/usr/bin/env python3
"""Unit tests for session-web.py — event extraction and JSON shaping.
Run: python3 claude/tests/test_session_web.py  (from repo root)
The script under test lives one level up, in claude/.
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


sa = _load("session_analytics", "session-analytics.py")
web = _load("session_web", "session-web.py")


def _kinds(events):
    return [e["kind"] for e in events]


class ClaudeEventsTest(unittest.TestCase):
    ROWS = [
        {"type": "attachment", "timestamp": "2026-07-24T10:00:00.000Z",
         "attachment": {"type": "hook_success", "hookEvent": "SessionStart",
                        "hookName": "startup", "content": "digest", "exitCode": 0,
                        "durationMs": 12}},
        {"type": "user", "timestamp": "2026-07-24T10:00:01.000Z",
         "message": {"content": "<command-name>/model</command-name>"}},
        {"type": "user", "timestamp": "2026-07-24T10:00:02.000Z",
         "message": {"content": "fix the widget"}},
        {"type": "assistant", "timestamp": "2026-07-24T10:00:03.000Z",
         "message": {"model": "claude-opus-5",
                     "usage": {"input_tokens": 10, "output_tokens": 5,
                               "cache_read_input_tokens": 100,
                               "cache_creation_input_tokens": 7},
                     "content": [{"type": "thinking", "thinking": "hmm"},
                                 {"type": "text", "text": "GOAL: fix it"},
                                 {"type": "tool_use", "id": "t1", "name": "Bash",
                                  "input": {"command": "ls -la"}}]}},
        {"type": "user", "timestamp": "2026-07-24T10:00:05.000Z",
         "message": {"content": [
             {"type": "tool_result", "tool_use_id": "t1", "is_error": True,
              "content": [{"type": "text", "text": "boom: not found"}]}]}},
        {"type": "system", "timestamp": "2026-07-24T10:00:06.000Z",
         "subtype": "stop_hook_summary"},
    ]

    def setUp(self):
        self.evs = web.extract_events(self.ROWS, "claude")

    def test_event_kinds_in_order(self):
        self.assertEqual(_kinds(self.evs),
                         ["hook", "context", "user", "assistant", "tool", "system"])

    def test_real_prompt_starts_a_turn_but_slash_command_does_not(self):
        user = [e for e in self.evs if e["kind"] == "user"]
        self.assertEqual(len(user), 1)
        self.assertEqual(user[0]["turn"], 1)
        self.assertEqual([e for e in self.evs if e["badge"] == "COMMAND"][0]["turn"], 0)

    def test_assistant_carries_tokens_thinking_and_model(self):
        a = [e for e in self.evs if e["kind"] == "assistant"][0]
        self.assertEqual(a["tokens"], {"input": 10, "output": 5,
                                       "cache_read": 100, "cache_create": 7})
        self.assertEqual(a["thinking"], "hmm")
        self.assertEqual(a["model"], "claude-opus-5")
        self.assertEqual(a["text"], "GOAL: fix it")

    def test_tool_result_merges_into_its_call(self):
        t = [e for e in self.evs if e["kind"] == "tool"][0]
        self.assertEqual(t["tool"]["name"], "Bash")
        self.assertIn("ls -la", t["tool"]["args"])
        self.assertEqual(t["tool"]["result"], "boom: not found")
        self.assertTrue(t["error"])
        self.assertEqual(t["dur_ms"], 2000)   # 10:00:03 -> 10:00:05
        self.assertEqual(t["step"], 2)        # after the assistant text step

    def test_hook_and_raw_payload(self):
        h = self.evs[0]
        self.assertIn("SessionStart:startup", h["title"])
        self.assertFalse(h["error"])
        self.assertEqual(json.loads(h["raw"])["attachment"]["hookName"], "startup")

    def test_system_reminder_text_is_context_not_a_turn(self):
        evs = web.extract_events([
            {"type": "user", "timestamp": "t", "message": {"content": [
                {"type": "text", "text": "<system-reminder>be terse</system-reminder>"}]}},
        ], "claude")
        self.assertEqual(_kinds(evs), ["context"])
        self.assertEqual(evs[0]["turn"], 0)

    def test_failed_hook_marks_error(self):
        evs = web.extract_events([
            {"type": "attachment", "attachment": {
                "type": "hook_success", "hookEvent": "PreToolUse",
                "hookName": "guard", "content": "blocked", "exitCode": 2}},
        ], "claude")
        self.assertTrue(evs[0]["error"])

    def test_orphan_tool_result_still_shows(self):
        evs = web.extract_events([
            {"type": "user", "timestamp": "t", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "nope", "content": "late"}]}},
        ], "claude")
        self.assertEqual(_kinds(evs), ["tool"])
        self.assertEqual(evs[0]["text"], "late")


class CopilotEventsTest(unittest.TestCase):
    def test_tool_request_and_completion_merge(self):
        rows = [
            {"type": "session.start", "timestamp": "2026-07-15T17:56:51.670Z",
             "data": {"sessionId": "s1", "context": {"cwd": "/tmp/p"}}},
            {"type": "user.message", "timestamp": "2026-07-15T17:56:54.070Z",
             "data": {"content": "make a file"}},
            {"type": "assistant.message", "timestamp": "2026-07-15T17:56:55.000Z",
             "data": {"model": "claude-haiku-4.5", "content": "on it",
                      "toolRequests": [{"toolCallId": "c1", "name": "create",
                                        "arguments": {"path": "/tmp/p/x.txt"}}]}},
            {"type": "tool.execution_complete", "timestamp": "2026-07-15T17:56:56.500Z",
             "data": {"toolCallId": "c1", "success": True,
                      "result": {"content": "Created file"}}},
            {"type": "hook.end", "timestamp": "2026-07-15T17:56:57.000Z",
             "data": {"hookType": "userPromptSubmitted", "success": False}},
        ]
        evs = web.extract_events(rows, "copilot")
        self.assertEqual(_kinds(evs), ["system", "user", "assistant", "tool", "hook"])
        tool = evs[3]
        self.assertEqual(tool["tool"]["result"], "Created file")
        self.assertEqual(tool["dur_ms"], 1500)
        self.assertFalse(tool["error"])
        self.assertTrue(evs[4]["error"])

    def test_failed_tool_records_error_message(self):
        rows = [
            {"type": "assistant.message", "timestamp": "2026-07-15T17:56:55.000Z",
             "data": {"content": "", "toolRequests": [
                 {"toolCallId": "c1", "name": "bash", "arguments": {"command": "nope"}}]}},
            {"type": "tool.execution_complete", "timestamp": "2026-07-15T17:56:55.500Z",
             "data": {"toolCallId": "c1", "success": False,
                      "error": {"message": "command not found"}}},
        ]
        evs = web.extract_events(rows, "copilot")
        self.assertTrue(evs[0]["error"])
        self.assertIn("command not found", evs[0]["tool"]["result"])


class PiEventsTest(unittest.TestCase):
    def test_pi_message_roles(self):
        rows = [
            {"type": "session", "timestamp": "2026-08-08T14:40:00.012Z",
             "id": "p1", "cwd": "/repo"},
            {"type": "custom_message", "timestamp": "2026-08-08T14:40:01.000Z",
             "customType": "claude-hooks-port", "content": "digest"},
            {"type": "message", "timestamp": "2026-08-08T14:41:51.501Z",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "read the doc"}]}},
            {"type": "message", "timestamp": "2026-08-08T14:41:54.114Z",
             "message": {"role": "assistant", "model": "deepseek-v4-pro",
                         "usage": {"input": 3, "output": 4, "cacheRead": 5,
                                   "cacheWrite": 6},
                         "content": [{"type": "text", "text": "reading"},
                                     {"type": "toolCall", "id": "call1",
                                      "name": "read",
                                      "arguments": {"path": "/repo/doc.md"}}]}},
            {"type": "message", "timestamp": "2026-08-08T14:41:55.114Z",
             "message": {"role": "toolResult", "toolCallId": "call1",
                         "toolName": "read",
                         "content": [{"type": "text", "text": "# doc"}]}},
        ]
        evs = web.extract_events(rows, "pi")
        self.assertEqual(_kinds(evs), ["system", "context", "user", "assistant", "tool"])
        self.assertEqual(evs[3]["tokens"],
                         {"input": 3, "output": 4, "cache_read": 5, "cache_create": 6})
        self.assertEqual(evs[4]["tool"]["result"], "# doc")
        self.assertEqual(evs[4]["dur_ms"], 1000)


class ShapingTest(unittest.TestCase):
    def _session(self):
        s = sa.Session(session_id="abc", path="/tmp/abc.jsonl", harness="claude",
                       project="/home/mohan/REPO/proj", title="Fix the widget",
                       user_turns=2, assistant_msgs=3, input_tokens=10,
                       output_tokens=20, cache_read=70, cache_creation=0,
                       tool_errors=1, goal="achieved")
        s.tools.update(["Bash", "Read", "Bash"])
        s.files_written.add("/tmp/new.py")
        s.errors.append({"tool": "Bash", "cmd": "ls", "msg": "boom", "sig": "Bash: boom"})
        return s

    def test_session_row_is_json_serializable_and_complete(self):
        row = web.session_row(self._session())
        json.dumps(row)   # must not raise: sets/Counters are converted
        self.assertEqual(row["project_short"], "proj")
        self.assertEqual(row["total_tokens"], 100)
        self.assertEqual(row["tool_mix"][0], ("Bash", 2))
        self.assertEqual(row["files"]["added"], ["/tmp/new.py"])
        self.assertEqual(row["goal"], "achieved")

    def test_dashboard_payload_matches_aggregate(self):
        d = web.dashboard_payload(sa, [self._session()])
        json.dumps(d)
        self.assertEqual(d["n_sessions"], 1)
        self.assertEqual(d["turns"], 2)
        self.assertEqual(d["tool_calls"], 3)
        self.assertEqual(d["goal_achieved"], 1)
        self.assertEqual(d["error_patterns"][0]["count"], 1)

    def test_clip_and_oneline(self):
        self.assertTrue(web._clip("x" * 100, 10).startswith("x" * 10))
        self.assertIn("+90 chars", web._clip("x" * 100, 10))
        self.assertEqual(web._oneline("a\n  b\tc"), "a b c")
        self.assertTrue(web._oneline("y" * 50, 10).endswith("…"))


class ScopeTest(unittest.TestCase):
    def test_scope_indexes_and_caches_events(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s1.jsonl")
            rows = [
                {"type": "user", "timestamp": "2026-07-24T10:00:00.000Z",
                 "cwd": d, "message": {"content": "hello"}},
                {"type": "assistant", "timestamp": "2026-07-24T10:00:01.000Z",
                 "message": {"model": "m", "usage": {},
                             "content": [{"type": "text", "text": "hi"}]}},
            ]
            with open(path, "w", encoding="utf-8") as fh:
                for r in rows:
                    fh.write(json.dumps(r) + "\n")

            scope = web.Scope(sa)
            scope.sessions = [sa.parse_session(rows, path=path, fallback_project=d)]
            scope.sessions[0].harness = "claude"
            scope.by_path = {path: scope.sessions[0]}

            evs, rep = scope.events(path)
            self.assertEqual(_kinds(evs), ["user", "assistant"])
            self.assertIs(scope.events(path)[0], evs)   # cached, same object
            self.assertIs(scope.events(path)[1], rep)
            self.assertEqual(scope.events("/nope.jsonl"), (None, None))


def _response(mid, out, ctx, blocks, ts="2026-07-24T10:00:00.000Z"):
    """One assistant row: ctx is what the model read, out what it wrote."""
    return {"type": "assistant", "timestamp": ts,
            "message": {"id": mid, "model": "m", "content": blocks,
                        "usage": {"input_tokens": ctx, "output_tokens": out,
                                  "cache_read_input_tokens": 0,
                                  "cache_creation_input_tokens": 0}}}


class TokenReportTest(unittest.TestCase):
    def test_output_total_matches_usage_and_splits_by_share(self):
        rows = [_response("m1", 300, 100, [
            {"type": "text", "text": "a" * 300},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"x": "b" * 87}},
        ])]
        rep = web.token_report(web.extract_events(rows, "claude"))
        self.assertEqual(rep["output"]["total"], 300)      # exact, never inflated
        by = {r["label"]: r["tokens"] for r in rep["output"]["rows"]}
        self.assertGreater(by["Reply text"], by["Tool calls"])
        self.assertNotIn("Thinking", by)                   # nothing hidden here
        self.assertEqual(sum(by.values()), 300)

    def test_usage_counted_once_per_response_across_split_rows(self):
        # Claude writes one response as several rows sharing message.id, each
        # repeating the usage; counting them all would double the totals.
        rows = [
            _response("m1", 500, 100, [{"type": "thinking", "thinking": "",
                                        "signature": "sig"}]),
            _response("m1", 500, 100, [{"type": "tool_use", "id": "t1",
                                        "name": "Bash", "input": {"c": "x" * 40}}]),
        ]
        rep = web.token_report(web.extract_events(rows, "claude"))
        self.assertEqual(rep["output"]["total"], 500)

    def test_stripped_thinking_becomes_the_residual(self):
        # A response billed far beyond what its visible text explains, carrying a
        # thinking block whose text the transcript dropped: the gap is thinking.
        rows = [
            _response("m1", 100, 100, [{"type": "text", "text": "z" * 400}]),
            _response("m2", 900, 200, [
                {"type": "thinking", "thinking": "", "signature": "sig"},
                {"type": "text", "text": "z" * 400},
            ]),
        ]
        evs = web.extract_events(rows, "claude")
        rep = web.token_report(evs)
        by = {r["label"]: r["tokens"] for r in rep["output"]["rows"]}
        self.assertEqual(rep["output"]["total"], 1000)
        # first response calibrates 4 chars/token, so the second's 400 visible
        # chars explain ~100 of its 900 tokens and the other ~800 are thinking.
        self.assertGreater(by["Thinking"], 700)
        self.assertTrue(any(e["est"].get("think") for e in evs))

    def test_context_growth_lands_on_what_arrived_between_requests(self):
        rows = [
            _response("m1", 10, 1000, [{"type": "tool_use", "id": "t1",
                                        "name": "Read", "input": {"file_path": "f"}}]),
            {"type": "user", "timestamp": "2026-07-24T10:00:02.000Z",
             "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                                      "content": "R" * 4000}]}},
            _response("m2", 10, 2000, [{"type": "text", "text": "done"}]),
        ]
        rep = web.token_report(web.extract_events(rows, "claude"))
        by = {r["label"]: r["tokens"] for r in rep["context"]["rows"]}
        # the 1000-token jump is the 4000-character Read result
        self.assertGreater(by["Tool results"], 700)
        self.assertEqual(by["System prompt & tools"], 1000)   # the first request
        self.assertEqual(rep["by_tool"][0]["label"], "Read")
        self.assertEqual(rep["reads"]["requests"], 2)
        self.assertEqual(rep["reads"]["context_reads"], 3000)

    def test_percentages_of_every_group_add_up(self):
        rows = [_response("m1", 400, 500, [
            {"type": "thinking", "thinking": "", "signature": "s"},
            {"type": "text", "text": "hello there"},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"c": "ls"}},
        ])]
        rep = web.token_report(web.extract_events(rows, "claude"))
        for group in ("output", "context"):
            pcts = sum(r["pct"] for r in rep[group]["rows"])
            self.assertAlmostEqual(pcts, 100.0, delta=0.3)
            self.assertEqual(sum(r["tokens"] for r in rep[group]["rows"]),
                             rep[group]["total"])

    def test_harness_without_usage_is_marked_estimated(self):
        rows = [
            {"type": "message", "timestamp": "2026-07-24T10:00:00.000Z",
             "message": {"role": "assistant", "id": "m1", "model": "m",
                         "content": [{"type": "text", "text": "y" * 400}]}},
        ]
        rep = web.token_report(web.extract_events(rows, "pi"))
        self.assertFalse(rep["exact"])
        self.assertEqual(rep["output"]["total"], 100)   # 400 chars / 4


if __name__ == "__main__":
    unittest.main(verbosity=2)

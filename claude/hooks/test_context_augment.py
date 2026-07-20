#!/usr/bin/env python3
"""Unit tests for context-augment.py. Run: python3 test_context_augment.py"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "context_augment", Path(__file__).with_name("context-augment.py"))
ca = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ca)

SCRIPT = str(Path(__file__).with_name("context-augment.py"))

# shared temp fixtures for render_file tier tests
_TMP = tempfile.TemporaryDirectory()
_TMP_ROOT = _TMP.name


def _small_rel():
    rel = "small.py"
    (Path(_TMP_ROOT) / rel).write_text(
        "class AuthService:\n    def login(self, user):\n        return True\n")
    return rel


def _large_rel():
    rel = "large.py"
    # >2500 chars so the full-content tier is skipped and abstract kicks in
    lines = [f"def fn_{i}(a, b):\n    payload_marker = a + b\n    return payload_marker\n"
             for i in range(120)]
    (Path(_TMP_ROOT) / rel).write_text("\n".join(lines))
    return rel


def run_main(prompt, cwd, session_id=None, env=None):
    payload = {"prompt": prompt, "cwd": cwd}
    if session_id:
        payload["session_id"] = session_id
    proc = subprocess.run(
        [sys.executable, SCRIPT],
        input=json.dumps(payload),
        capture_output=True, text=True, env=env,
    )
    return proc.stdout


class Keywords(unittest.TestCase):
    def test_paths_and_symbols(self):
        paths, syms = ca.extract_keywords(
            "Update src/auth.py so AuthService uses MAX_RETRY and get_user")
        self.assertIn("src/auth.py", paths)
        self.assertIn("AuthService", syms)
        self.assertIn("MAX_RETRY", syms)
        self.assertIn("get_user", syms)

    def test_drops_plain_words(self):
        # short lowercase words (<5 chars, no code shape) are not symbols
        _, syms = ca.extract_keywords("Please can you go fix the app now")
        self.assertEqual(syms, [])

    def test_strips_at_prefix(self):
        paths, _ = ca.extract_keywords("look at @config/settings.json now")
        self.assertIn("config/settings.json", paths)


class Abstraction(unittest.TestCase):
    def test_python_signatures(self):
        src = (
            "import os\n"
            "from typing import List\n\n"
            "class Foo(Base):\n"
            '    """A widget."""\n'
            "    def bar(self, x: int) -> str:\n"
            "        return str(x)\n\n"
            "async def top(y):\n"
            "    return y\n"
        )
        out = ca.abstract_python(src)
        self.assertIn("class Foo(Base):", out)
        self.assertIn("def bar(self, x: int) -> str:", out)
        self.assertIn("async def top(y):", out)
        self.assertIn('"""A widget."""', out)
        self.assertNotIn("return str(x)", out)

    def test_python_syntax_error_falls_back(self):
        out = ca.abstract_python("class Broken(:\n  def x(")
        self.assertIsInstance(out, str)

    def test_regex_js(self):
        src = ("export function login(user) {\n  return doStuff();\n}\n"
               "const secret = 42;\n")
        out = ca.abstract_regex(src)
        self.assertIn("export function login(user)", out)
        self.assertNotIn("doStuff", out)

    def test_condense_caps_length(self):
        self.assertLessEqual(len(ca.condense_prompt("word " * 200)), 404)


class Minify(unittest.TestCase):
    def test_strips_comments_and_blanks(self):
        src = ("# leading comment\n"
               "import os\n\n\n"
               "def f():\n"
               "    return 1\n")
        out = ca.minify_code(src, "py")
        self.assertNotIn("# leading comment", out)
        self.assertNotIn("\n\n", out)          # blank lines collapsed
        self.assertIn("import os", out)
        self.assertIn("return 1", out)         # code body preserved verbatim

    def test_preserves_hash_inside_string(self):
        src = 'url = "http://x#frag"\n'
        self.assertIn('url = "http://x#frag"', ca.minify_code(src, "py"))

    def test_small_file_full_mode(self):
        body, mode = ca.render_file(_TMP_ROOT, _small_rel())
        self.assertEqual(mode, "full")
        self.assertIn("return True", body)     # full content, not just signature

    def test_large_file_abstract_mode(self):
        body, mode = ca.render_file(_TMP_ROOT, _large_rel())
        self.assertEqual(mode, "abstract")
        self.assertIn("def fn_0", body)        # signature kept
        self.assertNotIn("payload_marker", body)  # body dropped


class EndToEnd(unittest.TestCase):
    def test_short_prompt_no_output(self):
        self.assertEqual(run_main("hi there", os.getcwd()), "")

    def test_finds_file(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "init", "-q"], cwd=d)
            (Path(d) / "auth_service.py").write_text(
                "class AuthService:\n    def login(self, user):\n        return True\n")
            out = run_main("Please fix AuthService login in auth_service.py now", d)
            self.assertIn("<context-augmentation>", out)
            self.assertIn('<file path="auth_service.py"', out)
            self.assertIn('mode="full"', out)      # small file -> full content
            self.assertIn("class AuthService:", out)
            self.assertIn("return True", out)      # no Read needed to see the body


class NoLedger(unittest.TestCase):
    """Injection is advisory: it must not write a ledger anything else gates Reads on."""

    def test_no_ledger_written(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as state_home:
            subprocess.run(["git", "init", "-q"], cwd=d)
            (Path(d) / "auth_service.py").write_text(
                "class AuthService:\n    def login(self, user):\n        return True\n")
            env = {**os.environ, "XDG_STATE_HOME": state_home}
            out = run_main("Please fix AuthService login in auth_service.py now", d,
                           session_id="ledger-test", env=env)
            self.assertIn('mode="full"', out)
            self.assertFalse(
                (Path(state_home) / "claude-hooks" / "ledger-test" / "context_shown.json").exists())


class KeywordPrecision(unittest.TestCase):
    def test_prose_words_are_not_symbols(self):
        _, symbols = ca.extract_keywords(
            "could you give me an honest review of the existing complex setup")
        self.assertEqual(symbols, [])

    def test_stopwords_match_case_insensitively(self):
        _, symbols = ca.extract_keywords("should we consider what happens here")
        self.assertNotIn("should", symbols)
        self.assertNotIn("consider", symbols)

    def test_code_shaped_tokens_still_kept(self):
        _, symbols = ca.extract_keywords("fix AuthService and get_user and MAX_RETRY")
        self.assertIn("AuthService", symbols)
        self.assertIn("get_user", symbols)
        self.assertIn("MAX_RETRY", symbols)

    def test_short_lowercase_word_dropped_long_kept(self):
        _, symbols = ca.extract_keywords("the parser broke in boilerplates")
        self.assertNotIn("parser", symbols)       # 6 chars, below MIN_WORD_LEN
        self.assertIn("boilerplates", symbols)


def _large_rel_in(root):
    rel = "large.py"
    lines = [f"def fn_{i}(a, b):\n    payload_marker = a + b\n    return payload_marker\n"
             for i in range(120)]
    (Path(root) / rel).write_text("\n".join(lines))
    return rel


if __name__ == "__main__":
    unittest.main(verbosity=2)

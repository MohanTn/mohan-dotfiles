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


def run_main(prompt, cwd):
    proc = subprocess.run(
        [sys.executable, SCRIPT],
        input=json.dumps({"prompt": prompt, "cwd": cwd}),
        capture_output=True, text=True,
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
        _, syms = ca.extract_keywords("Please make the thing work when ready")
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
            self.assertIn("class AuthService:", out)
            self.assertNotIn("return True", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""mcp/server.py - the tool surface an agent drives dx through.

The mcp package is not installed in the test environment (it lives in the MCP
container), so the module is loaded with a stub in place. What is under test is
this file's own logic - config reading, truncation, refusals, timeouts - not the
FastMCP framework.
"""

import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_server(dx_root):
    """Import mcp/server.py with a stubbed FastMCP and a chosen DX_ROOT."""
    stub = types.ModuleType("mcp")
    server_mod = types.ModuleType("mcp.server")
    fastmcp = types.ModuleType("mcp.server.fastmcp")

    class FakeMCP:
        def __init__(self, name):
            self.name = name
            self.tools = {}
            self.settings = types.SimpleNamespace(port=0, host="")

        def tool(self, *a, **k):
            def deco(fn):
                self.tools[fn.__name__] = fn
                return fn
            return deco

        def run(self, **k):  # pragma: no cover
            pass

    fastmcp.FastMCP = FakeMCP
    server_mod.fastmcp = fastmcp
    stub.server = server_mod
    for name, mod in [("mcp", stub), ("mcp.server", server_mod),
                      ("mcp.server.fastmcp", fastmcp)]:
        sys.modules[name] = mod

    import os
    old = os.environ.get("DX_ROOT")
    os.environ["DX_ROOT"] = str(dx_root)
    spec = importlib.util.spec_from_file_location("dxmcp", ROOT / "mcp" / "server.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    if old is None:
        os.environ.pop("DX_ROOT", None)
    else:
        os.environ["DX_ROOT"] = old
    return m


class TestConfigReading(unittest.TestCase):
    def test_reads_timeouts_from_the_resolved_cache(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".stack.env").write_text(
                "# comment\n"
                "STACK_MCP_TIMEOUT_TEST='4242'\n"
                "STACK_MCP_MAX_OUTPUT='1234'\n"
                "STACK_PORTS_MAIL_UI='9999'\n"
                "STACK_OUTPUT_ERROR_PATTERN='BOOM'\n")
            m = load_server(d)
        self.assertEqual(m.T_TEST, 4242)
        self.assertEqual(m.MAX_OUTPUT, 1234)
        self.assertEqual(m.MAIL_UI_PORT, 9999)
        self.assertEqual(m.ERROR_PATTERN, "BOOM")

    def test_falls_back_when_the_cache_does_not_exist_yet(self):
        # A fresh container must answer rather than crash.
        with tempfile.TemporaryDirectory() as d:
            m = load_server(d)
        self.assertGreater(m.DEFAULT_TIMEOUT, 0)
        self.assertGreater(m.MAX_OUTPUT, 0)

    def test_a_non_numeric_value_falls_back_rather_than_raising(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".stack.env").write_text("STACK_MCP_TIMEOUT_TEST='not-a-number'\n")
            m = load_server(d)
        self.assertIsInstance(m.T_TEST, int)

    def test_the_real_cache_is_read_when_present(self):
        m = load_server(ROOT)
        self.assertIsInstance(m.T_UP, int)
        self.assertGreater(m.T_UP, m.T_STATUS, "a build must be allowed longer than a status call")


class TestToolSurface(unittest.TestCase):
    def setUp(self):
        self.m = load_server(ROOT)
        self.tools = self.m.mcp.tools

    def test_expected_tools_are_registered(self):
        for name in ["dx_describe", "dx_status", "dx_preflight", "dx_doctor", "dx_verify",
                     "dx_logs", "dx_errors", "db_query", "db_snapshot", "db_snapshots",
                     "mail_latest", "dx_instances", "wt_add", "wt_remove",
                     "agent_spawn", "agent_diff", "agent_run", "agent_audit",
                     "policy_check", "dx_up", "dx_test", "dx_run"]:
            self.assertIn(name, self.tools, name)

    def test_every_tool_has_a_docstring_the_model_can_act_on(self):
        for name, fn in self.tools.items():
            self.assertTrue(fn.__doc__, "%s has no docstring" % name)
            self.assertGreater(len(fn.__doc__.strip()), 40,
                               "%s's docstring is too thin to guide a call" % name)

    def test_destructive_tools_require_an_explicit_confirmation(self):
        # An ambiguous prompt must not be able to become a removed worktree.
        out = self.tools["wt_remove"]("some-slug", drop_db=True, confirm=False)
        self.assertIn("REFUSED", out)
        self.assertIn("confirm=True", out)

    def test_db_query_refuses_what_needs_a_disposable_database(self):
        for sql in ["DROP DATABASE app_dev", "drop schema public",
                    "TRUNCATE TABLE users", "truncate users"]:
            out = self.tools["db_query"](sql)
            self.assertIn("REFUSED", out, sql)
            self.assertIn("dx_test", out, "the refusal must name the alternative")

    def test_db_query_allows_ordinary_statements(self):
        # It shells out to dx, which will fail without a stack - the point is
        # only that it was not refused before getting there.
        out = self.tools["db_query"]("SELECT 1")
        self.assertNotIn("REFUSED", out)


class TestRunHelper(unittest.TestCase):
    def setUp(self):
        self.m = load_server(ROOT)

    def test_a_missing_dx_is_reported_not_silently_empty(self):
        old = self.m.DX
        self.m.DX = "/nonexistent/dx"
        try:
            out = self.m._run(["describe"], timeout=5)
        finally:
            self.m.DX = old
        self.assertIn("ERROR", out)

    def test_a_failure_carries_its_exit_code(self):
        # A tool that returns "" on error teaches the model it succeeded.
        out = self.m._run(["definitely-not-a-command"], timeout=30)
        self.assertIn("exit ", out)

    def test_output_is_truncated_loudly(self):
        old = self.m.MAX_OUTPUT
        self.m.MAX_OUTPUT = 200
        try:
            out = self.m._run(["help"], timeout=30)
        finally:
            self.m.MAX_OUTPUT = old
        if len(out) > 200:
            self.assertIn("omitted", out, "truncation must announce itself")

    def test_a_timeout_reads_as_a_timeout_not_a_failure(self):
        # Point _run at sleep rather than at a dx verb: a dx command without a
        # running stack fails in milliseconds, so it would never time out and
        # the test would pass for the wrong reason.
        old = self.m.DX
        self.m.DX = "/bin/sleep"
        try:
            out = self.m._run(["5"], timeout=1)
        finally:
            self.m.DX = old
        self.assertIn("TIMEOUT", out)
        self.assertIn("dx_status", out, "and says what to do instead of retrying")


if __name__ == "__main__":
    unittest.main(verbosity=1)

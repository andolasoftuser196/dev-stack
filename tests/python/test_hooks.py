#!/usr/bin/env python3
"""claude-plugin/hooks - the guardrails.

stdlib unittest, no pytest: these tests must run wherever ssmd does, and adding a
dependency to test a component whose whole point is "works on a bare machine"
would be self-defeating.

The hooks speak JSON on stdin and JSON on stdout, so they are exercised as
subprocesses rather than imported. That is also the only way to catch the class
of bug where a hook crashes on import and Claude Code silently treats it as
"allow".
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOKS = ROOT / "claude-plugin" / "hooks"
sys.path.insert(0, str(HOOKS))

import ssmd_common  # noqa: E402


def run_hook(name, payload, env=None):
    """Invoke a hook and return (exit_code, parsed_output_or_None, stderr)."""
    e = {**os.environ, "SSMD_ROOT": str(ROOT), "CLAUDE_PROJECT_DIR": str(ROOT)}
    if env:
        e.update(env)
    p = subprocess.run(
        [sys.executable, str(HOOKS / name)],
        input=json.dumps(payload), capture_output=True, text=True, env=e, timeout=30,
    )
    out = None
    if p.stdout.strip():
        try:
            out = json.loads(p.stdout)
        except json.JSONDecodeError:
            out = {"__unparseable__": p.stdout}
    return p.returncode, out, p.stderr


def decision(out):
    return (out or {}).get("hookSpecificOutput", {}).get("permissionDecision")


def context(out):
    return (out or {}).get("hookSpecificOutput", {}).get("additionalContext", "")


class TestPosixRegexTranslation(unittest.TestCase):
    """The bug that made the whole command guard fail open.

    Python's `re` parses `[[:space:]]` as a character class containing
    [ : s p a c e - so every rule using POSIX classes matched nothing, the guard
    denied nothing, and the only symptom was a FutureWarning nobody reads.
    """

    def test_space_class_matches_a_space(self):
        rx = ssmd_common.compile_rule(r"docker[[:space:]]+compose")
        self.assertIsNotNone(rx)
        self.assertTrue(rx.search("docker compose up"))

    def test_untranslated_pattern_would_not_have_matched(self):
        """The control case: proves the translation is still necessary.

        Python warns about this pattern, which is the whole point - it is the
        warning the original bug hid behind. Suppressed here so a deliberate
        demonstration does not add noise to a passing run.
        """
        import re
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", FutureWarning)
            self.assertIsNone(re.compile(r"docker[[:space:]]+compose").search("docker compose up"),
                              "if this ever matches, the translation is no longer needed")

    def test_all_posix_classes(self):
        for cls, sample in [("alpha", "a"), ("digit", "7"), ("alnum", "z"),
                            ("space", " "), ("upper", "Q"), ("lower", "q"),
                            ("xdigit", "f"), ("blank", "\t")]:
            rx = ssmd_common.compile_rule(r"^[[:%s:]]$" % cls)
            self.assertIsNotNone(rx, cls)
            self.assertTrue(rx.match(sample), "%s should match %r" % (cls, sample))

    def test_malformed_rule_returns_none_not_an_exception(self):
        self.assertIsNone(ssmd_common.compile_rule("[unclosed"))


class TestGlobTranslation(unittest.TestCase):
    """`**` crosses separators, `*` does not.

    Getting that wrong permissively makes a rule for `config/*` also match
    `app/config/deep/x.php`, producing denials nobody can explain.
    """

    def m(self, glob, path):
        return bool(ssmd_common.glob_to_regex(glob).match(path))

    def test_doublestar_crosses_separators(self):
        self.assertTrue(self.m("**/composer.json", "composer.json"))
        self.assertTrue(self.m("**/composer.json", "a/b/c/composer.json"))

    def test_single_star_does_not_cross_separators(self):
        self.assertTrue(self.m("config/*.php", "config/app.php"))
        self.assertFalse(self.m("config/*.php", "config/deep/app.php"))

    def test_trailing_doublestar(self):
        self.assertTrue(self.m("migrations/**", "migrations/2024_x.php"))
        self.assertTrue(self.m("migrations/**", "migrations/a/b.php"))

    def test_rules_match_at_any_depth_for_monorepos(self):
        # A monorepo keeps the application in a subdirectory.
        self.assertTrue(self.m("routes/**", "apps/web/routes/api.php"))

    def test_question_mark(self):
        self.assertTrue(self.m("a?.txt", "ab.txt"))
        self.assertFalse(self.m("a?.txt", "abc.txt"))

    def test_dots_are_literal(self):
        self.assertTrue(self.m("*.env", "x.env"))
        self.assertFalse(self.m("*.env", "xaenv"))


class TestFindSsmdRoot(unittest.TestCase):
    def test_env_wins(self):
        self.assertEqual(ssmd_common.find_ssmd_root(), ROOT)

    def test_returns_none_outside_a_ssmd_project(self):
        # A hook that fires on unrelated repositories is a hook that gets
        # uninstalled, so "not a ssmd project" must be detectable. The search also
        # walks upward, so the temp dir must not be under a ssmd tree.
        for k in ("SSMD_ROOT", "CLAUDE_PLUGIN_OPTION_SSMD_ROOT",
                  "CLAUDE_PLUGIN_ROOT", "CLAUDE_PROJECT_DIR"):
            os.environ.pop(k, None)
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(ssmd_common.find_ssmd_root(d))

    def setUp(self):
        self._env = dict(os.environ)
        os.environ["SSMD_ROOT"] = str(ROOT)

    def tearDown(self):
        os.environ.clear(); os.environ.update(self._env)


class TestCommandGuard(unittest.TestCase):
    def deny(self, cmd):
        _, out, _ = run_hook("guard-command.py", {
            "tool_name": "Bash", "cwd": str(ROOT), "tool_input": {"command": cmd}})
        return decision(out) == "deny", out

    def test_denies_what_has_no_safe_version(self):
        for cmd in ["docker compose up -d", "docker-compose up",
                    "php artisan test", "vendor/bin/phpunit", "pytest tests/",
                    "go test ./...", "composer update", "npm install lodash",
                    "go mod tidy", "git reset --hard HEAD~1",
                    "git push --force origin main"]:
            denied, out = self.deny(cmd)
            self.assertTrue(denied, "should have denied: %s" % cmd)
            reason = out["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertIn("dev-stack policy", reason)

    def test_every_denial_names_an_alternative(self):
        # A guard that only says "denied" gets worked around.
        _, out, _ = run_hook("guard-command.py", {
            "tool_name": "Bash", "cwd": str(ROOT),
            "tool_input": {"command": "php artisan test"}})
        self.assertIn("ssmd test", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_allows_ordinary_work(self):
        for cmd in ["ls -la", "git status", "npm ci", "grep -r x .",
                    "git push origin feature", "cat README.md"]:
            denied, _ = self.deny(cmd)
            self.assertFalse(denied, "should have allowed: %s" % cmd)

    def test_commands_going_through_ssmd_are_never_denied(self):
        # ssmd's own guards are stricter than any regex; double-guarding would
        # deny the correct action.
        for cmd in ["./ssmd test", "ssmd up", "/usr/local/bin/ssmd db:drop x_test",
                    "cd /tmp && ./ssmd verify"]:
            denied, _ = self.deny(cmd)
            self.assertFalse(denied, "should have allowed: %s" % cmd)

    def test_mentioning_ssmd_in_an_argument_does_not_bypass(self):
        denied, _ = self.deny("docker compose up # ssmd")
        self.assertTrue(denied)

    def test_nudges_a_host_side_framework_cli_without_blocking(self):
        _, out, _ = run_hook("guard-command.py", {
            "tool_name": "Bash", "cwd": str(ROOT),
            "tool_input": {"command": "php artisan migrate"}})
        self.assertIsNone(decision(out), "must not block")
        self.assertIn("ssmd run", context(out))

    def test_outside_a_ssmd_project_it_does_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            env = {k: "" for k in ("SSMD_ROOT", "CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT")}
            rc, out, _ = run_hook("guard-command.py", {
                "tool_name": "Bash", "cwd": d,
                "tool_input": {"command": "docker compose up"}}, env=env)
            self.assertEqual(rc, 0)
            self.assertIsNone(decision(out))

    def test_empty_and_malformed_input_are_survivable(self):
        for payload in [{}, {"tool_name": "Bash"}, {"tool_input": {}}]:
            rc, _, err = run_hook("guard-command.py", payload)
            self.assertEqual(rc, 0, err)

    def test_no_stderr_noise_on_the_happy_path(self):
        # Warnings on every invocation train people to ignore the ones that matter.
        _, _, err = run_hook("guard-command.py", {
            "tool_name": "Bash", "cwd": str(ROOT), "tool_input": {"command": "ls"}})
        self.assertEqual(err.strip(), "")


class TestPathGuard(unittest.TestCase):
    def test_review_gate_warns_but_does_not_block(self):
        _, out, _ = run_hook("guard-path.py", {
            "tool_name": "Edit", "cwd": str(ROOT),
            "tool_input": {"file_path": str(ROOT.parent / "app/database/migrations/x.php")}})
        self.assertIsNone(decision(out), "the review gate must never block an edit")
        self.assertIn("review gate", context(out))
        self.assertIn("schema changes need eyes", context(out))

    def test_ordinary_file_passes_silently(self):
        _, out, _ = run_hook("guard-path.py", {
            "tool_name": "Edit", "cwd": str(ROOT),
            "tool_input": {"file_path": str(ROOT.parent / "app/src/Service.php")}})
        self.assertIsNone(decision(out))
        self.assertNotIn("review gate", context(out))

    def test_sandbox_confines_writes_to_the_worktree(self):
        for path in ["/etc/passwd", "/ssmd/lib/core.sh", "/tmp/x"]:
            _, out, _ = run_hook("guard-path.py", {
                "tool_name": "Write", "cwd": str(ROOT),
                "tool_input": {"file_path": path}}, env={"SSMD_SANDBOX": "1"})
            self.assertEqual(decision(out), "deny", "should have denied %s" % path)

    def test_sandbox_allows_its_own_worktree_and_home(self):
        for path in ["/app/src/x.php", "/app", "/home/agent/.bashrc"]:
            _, out, _ = run_hook("guard-path.py", {
                "tool_name": "Write", "cwd": str(ROOT),
                "tool_input": {"file_path": path}}, env={"SSMD_SANDBOX": "1"})
            self.assertNotEqual(decision(out), "deny", "should have allowed %s" % path)

    def test_confinement_is_inert_outside_a_sandbox(self):
        # On the host the human's own editing is not the thing being guarded.
        _, out, _ = run_hook("guard-path.py", {
            "tool_name": "Write", "cwd": str(ROOT),
            "tool_input": {"file_path": "/tmp/anything"}})
        self.assertIsNone(decision(out))


class TestVerifyReminder(unittest.TestCase):
    def _transcript(self, entries):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        for e in entries:
            f.write(json.dumps(e) + "\n")
        f.close()
        return f.name

    def _tool(self, name, inp):
        return {"message": {"content": [{"type": "tool_use", "name": name, "input": inp}]}}

    def test_notes_unverified_code_changes(self):
        t = self._transcript([self._tool("Edit", {"file_path": "/x/a.php"})])
        _, out, _ = run_hook("verify-reminder.py", {"cwd": str(ROOT), "transcript_path": t})
        self.assertIn("never ran", context(out))
        self.assertIn("unverified", context(out))
        os.unlink(t)

    def test_silent_when_verify_ran(self):
        t = self._transcript([self._tool("Edit", {"file_path": "/x/a.php"}),
                              self._tool("Bash", {"command": "./ssmd verify"})])
        _, out, _ = run_hook("verify-reminder.py", {"cwd": str(ROOT), "transcript_path": t})
        self.assertEqual(context(out), "")
        os.unlink(t)

    def test_silent_for_docs_only_changes(self):
        # Firing on a README edit is exactly the over-firing that gets a hook
        # uninstalled, taking the useful ones with it.
        t = self._transcript([self._tool("Edit", {"file_path": "/x/README.md"})])
        _, out, _ = run_hook("verify-reminder.py", {"cwd": str(ROOT), "transcript_path": t})
        self.assertEqual(context(out), "")
        os.unlink(t)

    def test_never_blocks(self):
        t = self._transcript([self._tool("Edit", {"file_path": "/x/a.php"})])
        rc, _, _ = run_hook("verify-reminder.py", {"cwd": str(ROOT), "transcript_path": t})
        self.assertEqual(rc, 0, "exit 2 would force another turn; a note is enough")
        os.unlink(t)

    def test_missing_transcript_is_survivable(self):
        rc, _, err = run_hook("verify-reminder.py",
                              {"cwd": str(ROOT), "transcript_path": "/no/such/file"})
        self.assertEqual(rc, 0, err)


class TestHooksManifest(unittest.TestCase):
    def test_every_referenced_script_exists_and_parses(self):
        cfg = json.loads((HOOKS / "hooks.json").read_text())
        seen = 0
        for event, groups in cfg["hooks"].items():
            for g in groups:
                for h in g["hooks"]:
                    cmd = h["command"]
                    self.assertIn("${CLAUDE_PLUGIN_ROOT}", cmd,
                                  "%s uses an absolute path" % event)
                    name = cmd.split("/")[-1].strip('"')
                    self.assertTrue((HOOKS / name).exists(), "%s missing" % name)
                    subprocess.run([sys.executable, "-m", "py_compile", str(HOOKS / name)],
                                   check=True, capture_output=True)
                    seen += 1
        self.assertGreaterEqual(seen, 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)

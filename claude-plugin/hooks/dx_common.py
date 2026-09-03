"""Shared helpers for the dx hooks.

Python rather than bash for one reason: the hook contract is JSON on stdin and
JSON on stdout, and parsing JSON in bash means either depending on jq (not always
present) or hand-rolling a parser (wrong, eventually, in a way that fails open).
A hook that fails open is worse than no hook, because it is trusted.

This is the one place in the toolkit that assumes python3. It is not part of the
dx command surface - `dx` itself runs on bash and docker alone - so a machine
without python3 loses the guardrails but keeps a working dev stack.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def read_input() -> dict:
    """Hook input, or an empty dict.

    Never raises. A malformed payload must not turn into a traceback on stderr
    that Claude Code shows the user as a broken hook - it should mean "this hook
    has nothing to say", which is what an empty dict produces downstream.
    """
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def find_dx_root(cwd: str | None = None) -> Path | None:
    """Locate the dev-stack directory.

    Four strategies, most explicit first:

    1. `DX_ROOT` in the environment.
    2. The plugin's user config (`CLAUDE_PLUGIN_OPTION_DX_ROOT`).
    3. Relative to the plugin itself - correct when the plugin is used in place
       from the repository, which is the normal case.
    4. A search upward from the working directory for a `dx` + `stack.yml` pair,
       checking `dev-stack/` at each level.

    Returns None rather than guessing. Every caller treats None as "not a dx
    project, stay out of the way" - a hook that fires on unrelated repositories
    is a hook that gets uninstalled.
    """
    for env in ("DX_ROOT", "CLAUDE_PLUGIN_OPTION_DX_ROOT"):
        v = os.environ.get(env)
        if v and (Path(v) / "dx").is_file():
            return Path(v)

    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plugin_root:
        cand = Path(plugin_root).parent
        if (cand / "dx").is_file() and (cand / "stack.yml").is_file():
            return cand

    start = Path(cwd or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
    for d in [start, *start.parents]:
        for cand in (d / "dev-stack", d):
            if (cand / "dx").is_file() and (cand / "stack.yml").is_file():
                return cand
    return None


def deny(event: str, reason: str) -> None:
    """Refuse the tool call, and say what to do instead.

    The reason text goes to the model, so it is written for the model: it names
    the alternative. A guard that only says "denied" gets worked around; a guard
    that says "use dx test" gets followed.
    """
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": event,
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, sys.stdout)
    sys.exit(0)


def add_context(event: str, text: str) -> None:
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": text,
        }
    }, sys.stdout)
    sys.exit(0)


def passthrough() -> None:
    sys.exit(0)


def load_rules(path: Path) -> list[tuple[str, str]]:
    """Read a policy TSV: <pattern><TAB><reason>, '#' comments, blank lines skipped."""
    rules: list[tuple[str, str]] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2 and parts[0].strip():
                rules.append((parts[0].strip(), parts[1].strip()))
    except OSError:
        pass
    return rules


# POSIX bracket expressions are valid in `grep -E`, which is what dx's own
# policy_check_command uses, and are NOT valid in Python's `re` - which parses
# `[[:space:]]` as "one of [ : s p a c e" and quietly matches nothing.
#
# That is a fail-open bug: the guard appears installed, denies nothing, and the
# only symptom is a FutureWarning nobody reads. One pattern file has to serve
# both engines, so the translation happens here rather than by writing the rules
# in a dialect only one of them understands.
_POSIX_CLASSES = {
    "[:alpha:]": "a-zA-Z",
    "[:digit:]": "0-9",
    "[:alnum:]": "a-zA-Z0-9",
    "[:space:]": r" \t\n\r\f\v",
    "[:upper:]": "A-Z",
    "[:lower:]": "a-z",
    "[:punct:]": r"!-/:-@\[-`{-~",
    "[:xdigit:]": "0-9A-Fa-f",
    "[:blank:]": r" \t",
}


def posix_regex_to_python(pattern: str) -> str:
    for posix, expansion in _POSIX_CLASSES.items():
        pattern = pattern.replace(posix, expansion)
    return pattern


def compile_rule(pattern: str) -> re.Pattern[str] | None:
    """Compile a policy pattern, or None if it is malformed.

    None means "skip this rule", never "deny everything" and never "allow
    everything by crashing". A broken rule is a bug in the policy file; it must
    not become an outage in the user's tooling.
    """
    try:
        return re.compile(posix_regex_to_python(pattern))
    except re.error:
        return None


def glob_to_regex(glob: str) -> re.Pattern[str]:
    """Translate the documented glob syntax to a regex.

    `**` crosses directory separators; `*` does not. Getting that distinction
    wrong in the permissive direction (treating `*` as crossing separators) makes
    a rule for `config/*` also match `app/config/deep/thing.php`, which produces
    denials nobody can explain.
    """
    out = ["(?:.*/)?"]  # allow the rule to match at any depth, for monorepos
    i = 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("/**", i):
            out.append("(?:/.*)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def audit(dx_root: Path, event: str, detail: str, decision: str = "allow") -> None:
    """Append one line to the tool audit trail.

    Best-effort by design: a full disk or a read-only mount must not turn into a
    blocked tool call. The audit is evidence, not a control.
    """
    try:
        from datetime import datetime, timezone
        p = dx_root / "data" / "state"
        p.mkdir(parents=True, exist_ok=True)
        with (p / "agent-tools.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "session": os.environ.get("CLAUDE_SESSION_ID", "")[:12],
                "event": event,
                "decision": decision,
                "detail": detail[:2000],
            }) + "\n")
    except Exception:
        pass


def dx(dx_root: Path, args: list[str], timeout: int = 20) -> str:
    try:
        p = subprocess.run(
            [str(dx_root / "dx"), *args], cwd=dx_root, capture_output=True,
            text=True, timeout=timeout, env={**os.environ, "NO_COLOR": "1"},
        )
        return (p.stdout or p.stderr or "").strip()
    except Exception:
        return ""

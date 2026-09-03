#!/usr/bin/env python3
"""PreToolUse(Bash) - refuse commands that have no safe version, and audit the rest.

Scope discipline matters here more than coverage. This hook fires on every Bash
call in every session where the plugin is enabled, so:

  - it does nothing at all outside a dx project (find_dx_root returns None);
  - it denies only what policy/denied-commands.tsv lists, and every entry there
    names the alternative;
  - it never blocks on its own judgement, and it never blocks on failure.

A guard that fires unpredictably gets disabled, and then the ones that mattered
are gone too.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from dx_common import (add_context, audit, compile_rule, deny,  # noqa: E402
                       find_dx_root, load_rules, passthrough, read_input)

EVENT = "PreToolUse"


def main() -> None:
    data = read_input()
    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd:
        passthrough()

    dx_root = find_dx_root(data.get("cwd"))
    if dx_root is None:
        passthrough()

    # A command that already goes through dx is by definition allowed: dx's own
    # guards (disposable-database checks, snapshot-before-drop, confirmation
    # prompts) are stricter than anything expressible as a regex, and
    # double-guarding produces denials of the correct action.
    #
    # Anchored to a path ending in /dx or a bare `dx`/`./dx` at the start of a
    # pipeline segment, so that a command merely mentioning "dx" in an argument
    # does not slip through.
    if re.search(r"(^|[;&|]\s*)(\./|/\S*/)?dx(\s|$)", cmd):
        audit(dx_root, "bash", cmd, "allow:dx")
        passthrough()

    for pattern, reason in load_rules(dx_root / "policy" / "denied-commands.tsv"):
        rx = compile_rule(pattern)
        if rx is None:
            # A malformed rule is a bug in the policy file, not grounds to block
            # the user's work. Skip it; `dx agent policy` is where it gets noticed.
            continue
        if rx.search(cmd):
            audit(dx_root, "bash", cmd, "deny")
            deny(EVENT, f"Blocked by dev-stack policy: {reason}\n\n"
                        f"  command: {cmd[:200]}\n"
                        f"  rule:    policy/denied-commands.tsv\n\n"
                        f"If this is genuinely the right thing to do, say so and let "
                        f"the human run it - do not rephrase the command to get past "
                        f"the rule.")

    audit(dx_root, "bash", cmd, "allow")

    # One nudge, not a block: a framework CLI run directly still works, it just
    # skips the environment dx would have set up. Saying so once is more useful
    # than denying it, because there are legitimate reasons to do it.
    if re.search(r"(^|[;&|]\s*)(php artisan|bin/cake|python manage\.py|npm run|go run)\s", cmd):
        add_context(EVENT,
                    "Note: this runs on the host, not in the app container, so it "
                    "will not see the stack's database or cache. The container "
                    "equivalent is `./dx run <command>`.")

    passthrough()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""PreToolUse(Edit|Write|NotebookEdit) - confine writes, and flag load-bearing paths.

Two behaviours with deliberately different force, and the distinction is the
whole design:

  **Deny** - writing outside the sandbox's own worktree, when running inside a
  sandbox. There is no legitimate version of that: the isolation is the reason
  the sandbox exists.

  **Warn** - editing a path on the review-gate list. The edit proceeds. A change
  to a migration or a lockfile is often exactly right; it just must not land
  unattended, and `dx agent diff` is where that is decided. Blocking it here
  would throw away correct work for touching a file, which is the failure mode
  the gate design exists to avoid.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from dx_common import (add_context, audit, deny, find_dx_root,  # noqa: E402
                       glob_to_regex, load_rules, passthrough, read_input)

EVENT = "PreToolUse"


def main() -> None:
    data = read_input()
    ti = data.get("tool_input") or {}
    target = ti.get("file_path") or ti.get("notebook_path") or ""
    if not target:
        passthrough()

    dx_root = find_dx_root(data.get("cwd"))
    if dx_root is None:
        passthrough()

    path = Path(target)

    # ── confinement ─────────────────────────────────────────────────────────
    # Only meaningful inside a sandbox, where DX_SANDBOX is set by the image.
    # On the host this hook must not restrict anything: the human's own editing
    # is not the thing being guarded.
    if os.environ.get("DX_SANDBOX") == "1":
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        # /app is the worktree; /home/agent is the sandbox's own home. Anything
        # else - including /dx, which is mounted read-only - is out of bounds.
        if not (str(resolved).startswith("/app/") or str(resolved) == "/app"
                or str(resolved).startswith("/home/agent")):
            audit(dx_root, "write", str(path), "deny:outside-worktree")
            deny(EVENT,
                 f"Blocked: {path} is outside this sandbox's worktree.\n\n"
                 f"A sandbox may write to /app (its own git worktree) and nowhere "
                 f"else. /dx is the toolkit, mounted read-only, and the human's "
                 f"checkout is not mounted at all.\n\n"
                 f"If the task genuinely requires changing something outside the "
                 f"worktree, it is not a task for a sandbox - say so.")

    # ── review-gate warning ─────────────────────────────────────────────────
    try:
        rel = str(path.resolve().relative_to(dx_root.parent.resolve()))
    except (ValueError, OSError):
        rel = str(path)

    for glob, reason in load_rules(dx_root / "policy" / "denied-paths.tsv"):
        if glob_to_regex(glob).match(rel) or glob_to_regex(glob).match(path.name):
            audit(dx_root, "write", rel, "warn:review-gate")
            add_context(EVENT,
                        f"Heads up - `{rel}` is on the review gate list.\n"
                        f"Reason: {reason}\n\n"
                        f"The edit is going ahead; this is not a block. But this "
                        f"change will be held for a human by `dx agent diff`, so "
                        f"do not treat it as landable unattended, and say clearly "
                        f"in your summary that it touches this file and why.")

    audit(dx_root, "write", rel, "allow")
    passthrough()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""SessionStart - tell the model what is actually running, once, at the start.

Without this, the first three turns of every session are spent rediscovering the
runtime, whether the stack is up, and which verbs exist. That is cheap for a
human to ask and expensive for a model to guess wrong about: guessing `dx artisan`
in a Go project produces a confident, useless plan.

Kept short on purpose. This is prepended to a session that has not started yet;
a wall of text here displaces the user's actual request.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from dx_common import add_context, dx, find_dx_root, passthrough, read_input  # noqa: E402


def main() -> None:
    data = read_input()
    dx_root = find_dx_root(data.get("cwd"))
    if dx_root is None:
        passthrough()

    describe = dx(dx_root, ["describe"], timeout=15)
    if not describe:
        passthrough()

    running = dx(dx_root, ["status"], timeout=20)
    up = "running" in running

    lines = [
        f"This project has a dx dev-stack at `{dx_root}`.",
        "",
        describe,
        "",
    ]
    if up:
        lines += [
            "The stack is up. Use `./dx run <cmd>` rather than running the "
            "framework CLI on the host, and `./dx verify` to check your work.",
        ]
    else:
        lines += [
            "The stack is **not running**. Start it with `./dx up` before "
            "anything that needs the app, the database or the cache.",
        ]
    lines += [
        "",
        "Never use raw `docker compose` here - it starts everything as root and "
        "the next file the app writes becomes uneditable on the host.",
    ]

    add_context("SessionStart", "\n".join(lines))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Stop - if code changed and nothing verified it, say so before the turn ends.

The cheapest possible quality control: a turn that edited application code and
never ran `dx verify` or `dx test` has produced an unverified claim, and the
moment to notice is before the human reads the summary, not after they deploy it.

It does not block. Exit 2 would force another turn, and forcing a verify on a
turn that only edited a README is exactly the kind of over-firing that gets a
hook uninstalled. A note is enough - the model reads it and either verifies or
says plainly that it did not.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from dx_common import find_dx_root, passthrough, read_input  # noqa: E402

# Extensions that mean "application behaviour may have changed". Deliberately
# excludes docs, config-as-data and lockfiles: those need review, not a health
# probe, and the review gate already covers them.
CODE_SUFFIXES = {".php", ".py", ".go", ".js", ".ts", ".jsx", ".tsx", ".vue",
                 ".rb", ".java", ".kt", ".rs", ".sql"}


def main() -> None:
    data = read_input()
    dx_root = find_dx_root(data.get("cwd"))
    if dx_root is None:
        passthrough()

    transcript = data.get("transcript_path")
    if not transcript or not Path(transcript).exists():
        passthrough()

    edited: set[str] = set()
    verified = False
    try:
        with open(transcript, encoding="utf-8") as f:
            for line in f:
                if '"name"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                for block in (entry.get("message", {}) or {}).get("content", []) or []:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name, inp = block.get("name"), block.get("input", {}) or {}
                    if name in ("Edit", "Write", "NotebookEdit"):
                        p = inp.get("file_path") or inp.get("notebook_path") or ""
                        if Path(p).suffix in CODE_SUFFIXES:
                            edited.add(p)
                    elif name == "Bash":
                        c = inp.get("command", "")
                        if "dx verify" in c or "dx test" in c:
                            verified = True
    except OSError:
        passthrough()

    if not edited or verified:
        passthrough()

    sample = ", ".join(sorted(Path(p).name for p in list(edited)[:3]))
    more = f" (+{len(edited) - 3} more)" if len(edited) > 3 else ""
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": (
                f"This turn changed application code ({sample}{more}) but never ran "
                f"`./dx verify` or `./dx test`.\n\n"
                f"`dx verify` is cheap and checks for new errors in the log since "
                f"the last run - which is the only thing that answers whether this "
                f"change broke something. Either run it, or state plainly in your "
                f"summary that the change is unverified. Do not describe it as "
                f"working."
            ),
        }
    }, sys.stdout)
    sys.exit(0)


if __name__ == "__main__":
    main()

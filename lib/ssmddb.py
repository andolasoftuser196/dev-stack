#!/usr/bin/env python3
"""SQLite backend for ssmd when sqlite3(1) is not installed.

Reads SQL from stdin and writes rows to stdout separated by U+001F, byte-for-byte
what `sqlite3 -batch -noheader -separator $'\x1f'` produces, so lib/sqlite.sh can
swap backends without any caller noticing.

The separator is not a tab on purpose: tab is IFS whitespace, and bash's `read`
collapses runs of it, so an empty column would vanish and shift every field after
it. See the note in lib/sqlite.sh.

Deliberately minimal. This is a compatibility shim, not a second implementation
of the config layer: everything that knows what the rows *mean* lives in
lib/config.sh, in one place, regardless of which backend fetched them.
"""

from __future__ import annotations

import sqlite3
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: ssmddb.py <database>", file=sys.stderr)
        return 2

    script = sys.stdin.read()
    conn = sqlite3.connect(sys.argv[1])
    try:
        # WAL so a long-running read (a `ssmd status` in another terminal) never
        # blocks a write. Matches what schema.sql sets; harmless to repeat.
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        # Per-connection, like journal_mode above. Without it ON DELETE CASCADE
        # never fires and a removed instance leaves its lease behind.
        conn.execute("PRAGMA foreign_keys=ON")

        # executescript() cannot return rows, and execute() cannot run several
        # statements. Callers do both, so: run the script for its effects, then
        # re-run the final statement to capture any result set it produced.
        statements = [s for s in script.split(";") if s.strip()]
        if not statements:
            return 0

        conn.executescript(script)

        last = statements[-1].strip()
        if last.upper().startswith(("SELECT", "PRAGMA", "WITH", "VALUES")):
            cur = conn.execute(last)
            out = sys.stdout
            for row in cur.fetchall():
                out.write("\x1f".join("" if v is None else str(v) for v in row))
                out.write("\n")
        conn.commit()
    except sqlite3.Error as e:
        print(f"ssmddb: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

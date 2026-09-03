"""The ssmd demo status probe, shared by every Python demo app.

TCP reachability rather than a driver per service: importing psycopg, redis and
an SMTP client only to answer "is it reachable" would make the demo's dependency
list larger than the demo itself.
"""

from __future__ import annotations

import os
import socket
import sys


def reachable(host: str, port: int, timeout: float = 5.0) -> bool:
    try:
        with socket.create_connection((host, int(port)), timeout):
            return True
    except OSError:
        return False


def status(framework: str) -> str:
    e = os.environ
    lines = [
        "ssmd demo app",
        "runtime=%s framework=%s version=%d.%d.%d"
        % (e.get("SSMD_RUNTIME", "python"), framework, *sys.version_info[:3]),
        "instance=%s" % e.get("SSMD_INSTANCE", "main"),
    ]

    db = e.get("DB_DATABASE")
    lines.append(
        "database=%s %s" % (db, "ok" if reachable(e.get("DB_HOST", ""), e.get("DB_PORT", 0)) else "FAILED")
        if db else "database=skipped"
    )

    lines.append(
        "cache=db%s %s" % (e.get("REDIS_DB", "0"),
                           "ok" if reachable(e.get("REDIS_HOST", ""), e.get("REDIS_PORT", 6379)) else "FAILED")
        if e.get("REDIS_HOST") else "cache=skipped"
    )

    lines.append(
        "mail=%s" % ("ok" if reachable(e.get("MAIL_HOST", ""), e.get("MAIL_PORT", 1025)) else "FAILED")
        if e.get("MAIL_HOST") else "mail=skipped"
    )

    lines.append("storage=%s" % ("ok" if e.get("S3_ENDPOINT") else "skipped"))
    return "\n".join(lines) + "\n"

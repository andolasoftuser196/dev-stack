#!/usr/bin/env python3
"""Stack-control MCP server - ssmd as tools.

Why this exists rather than letting the agent shell out to ssmd: a tool call has a
typed signature, a docstring the model reads before calling, and a result the
model does not have to parse out of terminal output. Shelling out gives you none
of that, and the failure mode is an agent that runs `ssmd up` four times because it
could not tell whether the first one worked.

Design rules, all of them learned the hard way:

**Read-heavy.** Most of the surface is read-only, because most of what an agent
needs from a dev stack is information. The write operations are the ones a human
would also want a confirmation dialog for.

**Destructive operations require an explicit flag.** Not because the model is
untrustworthy, but because an ambiguous prompt should not be able to become a
dropped database. `confirm=True` has to come from somewhere, and the somewhere is
a decision the model made explicitly and that shows up in the transcript.

**Every result says what happened, including failures.** A tool that returns ""
on error teaches the model that the operation succeeded. Exit codes and stderr
are always in the result.

**No output is silently truncated.** When it is truncated, the result says so and
says how to get the rest. An agent that thinks it has read the whole log and has
not will confidently diagnose the wrong thing.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:  # pragma: no cover
    print("mcp package missing: pip install -r mcp/requirements.txt", file=sys.stderr)
    raise SystemExit(1)

SSMD_ROOT = Path(os.environ.get("SSMD_ROOT", Path(__file__).resolve().parent.parent))
SSMD = str(SSMD_ROOT / "ssmd")


def _config() -> dict[str, str]:
    """Read the resolved configuration.

    From .stack.env, the flat cache ssmd maintains - not from the database
    directly. Two reasons: the cache is exactly what ssmd itself is using, so the
    server cannot disagree with the CLI about a timeout; and reading it needs no
    sqlite binding in this container, whose image is a bare python:slim.

    If the cache is missing (ssmd has never run here), every lookup falls back to
    the literal defaults below. Those are the only numbers in this file, and they
    exist so a fresh container answers rather than crashing.
    """
    cfg: dict[str, str] = {}
    try:
        for line in (SSMD_ROOT / ".stack.env").read_text().splitlines():
            if line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip().strip("'")
    except OSError:
        pass
    return cfg


CFG = _config()


def _num(key: str, fallback: int) -> int:
    try:
        return int(CFG.get(f"STACK_{key}", fallback))
    except (TypeError, ValueError):
        return fallback


# Every timeout and limit comes from the config database. A single global
# timeout would either kill a legitimate `ssmd up` or let a wedged test run hold
# the session open, so they are per operation - and tunable without editing this
# file:  ssmd config set mcp.timeout_test 7200
DEFAULT_TIMEOUT = _num("TIMEOUTS_MCP_DEFAULT", 900)
MAX_OUTPUT = _num("MCP_MAX_OUTPUT", 60_000)
T_DESCRIBE = _num("MCP_TIMEOUT_DESCRIBE", 30)
T_STATUS = _num("MCP_TIMEOUT_STATUS", 60)
T_PREFLIGHT = _num("MCP_TIMEOUT_PREFLIGHT", 120)
T_DOCTOR = _num("MCP_TIMEOUT_DOCTOR", 120)
T_VERIFY = _num("MCP_TIMEOUT_VERIFY", 180)
T_LOGS = _num("MCP_TIMEOUT_LOGS", 120)
T_QUERY = _num("MCP_TIMEOUT_QUERY", 120)
T_SNAPSHOT = _num("MCP_TIMEOUT_SNAPSHOT", 600)
T_UP = _num("MCP_TIMEOUT_UP", 2400)
T_TEST = _num("MCP_TIMEOUT_TEST", 3600)
T_INSTANCE = _num("MCP_TIMEOUT_INSTANCE", 1800)
ERROR_PATTERN = CFG.get(
    "STACK_OUTPUT_ERROR_PATTERN",
    r'"level":"(error|critical|emergency)"|\b(fatal error|uncaught|exception|traceback|panic:)\b',
)
MAIL_UI_PORT = _num("PORTS_MAIL_UI", 8025)

mcp = FastMCP("ssmd-devstack")


def _run(args: list[str], timeout: int = DEFAULT_TIMEOUT, stdin: str | None = None) -> str:
    """Run ssmd and return a result the model can act on.

    NO_COLOR because escape sequences in a tool result are noise the model then
    tries to interpret as content. SSMD_ACTOR so the audit log distinguishes what
    an agent did from what a human did - which is the entire point of having one.
    """
    env = {
        **os.environ,
        "NO_COLOR": "1",
        "SSMD_ACTOR": os.environ.get("SSMD_ACTOR", "mcp"),
        # An MCP call has no terminal, so anything that would prompt must fail
        # rather than hang. ssmd's confirm() already refuses without a TTY; this is
        # belt and braces for anything that shells out further.
        "DEBIAN_FRONTEND": "noninteractive",
    }
    try:
        p = subprocess.run(
            [SSMD, *args], cwd=SSMD_ROOT, capture_output=True, text=True,
            timeout=timeout, input=stdin, env=env,
        )
    except subprocess.TimeoutExpired:
        return (f"TIMEOUT after {timeout}s: ssmd {' '.join(args)}\n"
                f"The command is still running in the background or wedged. "
                f"Check with ssmd_status() before retrying - retrying a slow "
                f"`ssmd up` starts a second build.")
    except FileNotFoundError:
        return f"ERROR: ssmd not found at {SSMD}. Is SSMD_ROOT correct?"

    out = (p.stdout or "") + (("\n[stderr]\n" + p.stderr) if p.stderr.strip() else "")
    if len(out) > MAX_OUTPUT:
        head, tail = out[: MAX_OUTPUT // 2], out[-MAX_OUTPUT // 2:]
        out = (f"{head}\n\n... [{len(out) - MAX_OUTPUT} characters omitted from the "
               f"middle] ...\n\n{tail}")
    if p.returncode != 0:
        out = f"exit {p.returncode}\n\n{out}"
    return out.strip() or f"(no output, exit {p.returncode})"


# ── read-only: what is going on ─────────────────────────────────────────────

@mcp.tool()
def ssmd_describe() -> str:
    """The stack's configuration: runtime, services, paths, agent limits.

    Call this first in a session. It tells you which language runtime, which
    database engine, and which verbs exist, so you do not have to guess whether
    this project uses `ssmd artisan` or `ssmd manage`.
    """
    return _run(["describe"], timeout=T_DESCRIBE)


@mcp.tool()
def ssmd_status() -> str:
    """Container states and health for every service in the stack, plus URLs."""
    return _run(["status"], timeout=T_STATUS)


@mcp.tool()
def ssmd_preflight() -> str:
    """Check whether this machine can run the stack: docker, ports, DNS, disk, RAM.

    Read-only. Run it when `ssmd up` failed and the reason was not obvious - most
    "the stack will not start" problems are a port conflict or a missing group
    membership, and this names them directly.
    """
    return _run(["preflight"], timeout=T_PREFLIGHT)


@mcp.tool()
def ssmd_doctor() -> str:
    """Find drift between what ssmd believes and what is actually there.

    Read-only, never fixes anything. Reports: containers that should be running
    and are not, instances whose worktree or database has disappeared, orphaned
    proxy routes, and expired agent leases. Exits non-zero when it finds drift,
    which is reported in the result.
    """
    return _run(["doctor"], timeout=T_DOCTOR)


@mcp.tool()
def ssmd_verify(instance: str = "main") -> str:
    """Check whether the app actually works right now - the strongest signal available.

    This is the tool to call after making a change. It checks, in order: the
    container is up, the web server answers healthz, the app answers through the
    proxy, the database is reachable *from the app container*, the schema has
    tables, and - most usefully - whether any new error lines appeared in the log
    since the last verify.

    That last check is the one that answers "did what I just did break
    something", which no amount of reading the diff can.

    Args:
        instance: "main", or a worktree/agent slug from ssmd_instances().
    """
    return _run(["verify", instance], timeout=T_VERIFY)


@mcp.tool()
def ssmd_logs(service: str = "app", tail: int = 200, pattern: str = "") -> str:
    """Container logs, optionally filtered.

    Args:
        service: app, queue, scheduler, proxy, mysql, postgres, redis, mailpit, ...
        tail: how many lines from the end.
        pattern: an extended regex; only matching lines are returned. Use this -
            an unfiltered 200-line log is mostly request noise, and the three
            lines you want are easier to find with a pattern than to read past.
    """
    out = _run(["logs", "--tail", str(tail), service], timeout=T_LOGS)
    if pattern:
        import re
        try:
            rx = re.compile(pattern, re.I)
        except re.error as e:
            return f"ERROR: bad pattern {pattern!r}: {e}"
        lines = [l for l in out.splitlines() if rx.search(l)]
        return "\n".join(lines) if lines else f"(no lines matching {pattern!r} in the last {tail})"
    return out


@mcp.tool()
def ssmd_errors(service: str = "app", since: str = "30m") -> str:
    """Just the error lines from a service's log - the fast path to a diagnosis.

    A convenience over ssmd_logs with the pattern that matters, across every log
    format the runtimes emit (JSON level fields, PHP fatals, Python tracebacks,
    Go panics).

    Args:
        service: which container.
        since: a docker duration, e.g. "10m", "1h".
    """
    cmd = (f"docker logs --since {shlex.quote(since)} "
           f"$(docker ps -qf name={shlex.quote(service)} | head -1) 2>&1 | "
           f"grep -iE {shlex.quote(ERROR_PATTERN)} | tail -40")
    p = subprocess.run(["bash", "-lc", cmd], cwd=SSMD_ROOT, capture_output=True, text=True, timeout=60)
    return (p.stdout or "").strip() or f"(no errors in {service} since {since})"


# ── read-only: data ─────────────────────────────────────────────────────────

@mcp.tool()
def db_query(sql: str) -> str:
    """Run one SQL statement against the development database.

    Use this instead of the framework's ORM or a REPL when the question is about
    data rather than about code - it is faster and the result is easier to read.

    Writes are permitted (it is a dev database) but DROP and TRUNCATE are refused
    here: if you need a clean table, you need a disposable database, and `ssmd test`
    already gives the suite one.
    """
    lowered = sql.lower()
    for banned in ("drop database", "drop schema", "truncate"):
        if banned in lowered:
            return (f"REFUSED: '{banned}' is not available through this tool.\n"
                    f"A test that needs a clean table should run through ssmd_test(), "
                    f"which points the suite at a disposable database. To drop a "
                    f"disposable database deliberately, use ssmd db:drop on the "
                    f"command line - it snapshots first.")
    return _run(["db:query", sql], timeout=T_QUERY)


@mcp.tool()
def db_snapshot(label: str = "manual") -> str:
    """Snapshot the development database to data/snapshots/.

    Cheap, and the thing to do before any change you are not sure about. New
    worktree and agent instances are provisioned from the most recent snapshot,
    so a good one also makes every future instance start fast.
    """
    return _run(["db:snapshot", "", label], timeout=T_SNAPSHOT)


@mcp.tool()
def db_snapshots() -> str:
    """List available snapshots with sizes and dates."""
    return _run(["db:snapshots"], timeout=T_DESCRIBE)


@mcp.tool()
def mail_latest(limit: int = 10) -> str:
    """The most recent messages the app sent, from the mail catcher.

    Every outbound mail lands in Mailpit and nowhere else, which makes this the
    reliable way to assert on mail - far better than checking a notifications
    table and hoping the send actually happened.
    """
    try:
        with urllib.request.urlopen(
            f"http://localhost:{MAIL_UI_PORT}/api/v1/messages?limit={int(limit)}", timeout=10
        ) as r:
            data = json.load(r)
    except Exception as e:
        return (f"could not reach the mail catcher: {e}\n"
                f"Is it running? ssmd_status() will say. It is in the 'mailpit' profile.")
    msgs = data.get("messages", [])
    if not msgs:
        return "(no messages)"
    lines = []
    for m in msgs:
        to = ", ".join(a.get("Address", "") for a in m.get("To", []))
        lines.append(f"{m.get('Created', '')}  {m.get('From', {}).get('Address', '')} -> {to}\n"
                     f"    {m.get('Subject', '')}\n    id={m.get('ID', '')}")
    return "\n".join(lines)


# ── instances ───────────────────────────────────────────────────────────────

@mcp.tool()
def ssmd_instances() -> str:
    """Every worktree and agent instance: slug, branch, state, lease, URL."""
    return _run(["wt", "ls"], timeout=T_DESCRIBE)


@mcp.tool()
def wt_add(branch: str, slug: str = "", empty_db: bool = False) -> str:
    """Create a worktree instance: a full environment for one branch.

    It gets its own checkout, database, Redis logical database, storage bucket
    and a route at https://<slug>.<domain>/ - sharing the base stack's database
    server rather than running its own, which is what makes several of them
    affordable at once.

    Args:
        branch: the branch to check out. Created off the current HEAD if new.
        slug: subdomain and identifier. Derived from the branch name if omitted.
        empty_db: skip seeding from the most recent snapshot. Slower to become
            useful, but correct when you are testing the migration chain itself.
    """
    args = ["wt", "add", branch]
    if slug:
        args += ["--slug", slug]
    if empty_db:
        args += ["--empty-db"]
    return _run(args, timeout=T_INSTANCE)


@mcp.tool()
def wt_remove(slug: str, drop_db: bool = False, confirm: bool = False) -> str:
    """Remove a worktree instance.

    Args:
        slug: which instance.
        drop_db: also drop its database. A snapshot is taken first regardless,
            and the removal is abandoned if that snapshot fails.
        confirm: must be True. This deletes a working tree - if it holds
            uncommitted work, that work is gone.
    """
    if not confirm:
        return ("REFUSED: pass confirm=True.\n"
                "This removes a git worktree; uncommitted changes in it are lost. "
                "Check first: ssmd_run('git -C <worktree> status').")
    args = ["wt", "rm", slug]
    if drop_db:
        args += ["--drop-db"]
    return _run(args, timeout=T_SNAPSHOT)


# ── agent sandboxes ─────────────────────────────────────────────────────────

@mcp.tool()
def agent_spawn(branch: str, slug: str = "", owner: str = "claude",
                ttl: str = "4h", egress: str = "allowlist") -> str:
    """Create an isolated sandbox for a coding agent to work in.

    A worktree instance plus: a container the agent runs inside, on a network with
    no route off the machine except an allowlist proxy; the worktree as the only
    writable path into the repository; capped CPU, memory and process count; and a
    lease so a crashed agent does not hold the slot forever.

    Args:
        branch: the branch to work on.
        slug: identifier and subdomain. Derived from the branch if omitted.
        owner: who holds the lease. Shows in `ssmd agent ls` and the audit log.
        ttl: lease duration, e.g. "4h", "30m".
        egress: "allowlist" (policy/allow-hosts.txt), "none" (no outbound at
            all), or "full" (normal networking - a development convenience, not a
            posture for an unattended run).
    """
    args = ["agent", "spawn", branch, "--owner", owner, "--ttl", ttl, "--egress", egress]
    if slug:
        args += ["--slug", slug]
    return _run(args, timeout=T_INSTANCE)


@mcp.tool()
def agent_diff(slug: str) -> str:
    """What an agent changed, and whether it could land without a human.

    Evaluates the instance's changes against policy/denied-paths.tsv and the size
    caps. A verdict of "held" does NOT mean the change is wrong - it means the
    change touches something where a plausible-looking edit is dangerous
    (migrations, tenancy scoping, lockfiles, CI config) or is simply too large to
    review in one sitting.

    Read the reason. It is recorded per rule precisely so that "why is this held"
    is answerable without reading the policy file.
    """
    return _run(["agent", "diff", slug], timeout=T_QUERY)


@mcp.tool()
def agent_run(slug: str, command: str) -> str:
    """Run one command inside an agent sandbox.

    The sandbox has the project's toolchain, the worktree at /app, ssmd read-only
    at /ssmd, and no route off the machine except the allowlist proxy.
    """
    return _run(["agent", "run", slug, command], timeout=DEFAULT_TIMEOUT)


@mcp.tool()
def agent_audit(limit: int = 50) -> str:
    """The audit trail: what has actually been done to this stack, and by whom.

    Every state-changing ssmd command appends here, tagged with the actor. This is
    how "what did the agent do" gets answered without relying on the agent's own
    account of it.
    """
    return _run(["agent", "audit", "-n", str(int(limit))], timeout=T_DESCRIBE)


@mcp.tool()
def policy_check(command: str) -> str:
    """Would this shell command be refused by policy, and why?

    Ask before running something you are unsure about. The answer names the
    alternative - the rules exist to redirect, not merely to forbid.
    """
    script = f'. "{SSMD_ROOT}/lib/core.sh"; SSMD_ROOT="{SSMD_ROOT}"; . "{SSMD_ROOT}/lib/policy.sh"; ' \
             f'if reason=$(policy_check_command {shlex.quote(command)}); then ' \
             f'echo "ALLOWED"; else echo "DENIED: $reason"; fi'
    p = subprocess.run(["bash", "-c", script], cwd=SSMD_ROOT, capture_output=True, text=True, timeout=30)
    return (p.stdout or p.stderr or "").strip()


# ── the small number of write operations ────────────────────────────────────

@mcp.tool()
def ssmd_up(preset: str = "default") -> str:
    """Start the stack.

    Args:
        preset: core (app and backing services), default (+ queue, scheduler),
            tools (+ database and cache web UIs), full (+ browser, MCP).

    Slow on a cold cache - it builds the runtime image and installs dependencies.
    If it times out, call ssmd_status() rather than retrying: a second `ssmd up`
    starts a second build.
    """
    return _run(["up", preset], timeout=T_UP)


@mcp.tool()
def ssmd_test(args: str = "") -> str:
    """Run the project's test suite, pointed at a disposable database.

    Always use this rather than the framework's test runner directly. The bare
    runner reads whatever database the config names, and a suite that refreshes
    the schema will then drop every table in the development database. ssmd creates
    and targets `<db>_test` instead, and refuses to run if it cannot.

    Args:
        args: filters passed through, e.g. "--filter=UserTest" or "./internal/...".
    """
    return _run(["test", *shlex.split(args)] if args else ["test"], timeout=T_TEST)


@mcp.tool()
def ssmd_run(command: str) -> str:
    """Run a command in the app container, as the invoking user.

    For anything the framework can answer - a REPL one-liner, a CLI command, a
    migration status check. Faster and more reliable than driving the UI.
    """
    return _run(["run", command], timeout=DEFAULT_TIMEOUT)


if __name__ == "__main__":
    if "--http" in sys.argv:
        port = 8080
        if "--port" in sys.argv:
            port = int(sys.argv[sys.argv.index("--port") + 1])
        mcp.settings.port = port
        mcp.settings.host = "0.0.0.0"
        mcp.run(transport="streamable-http")
    else:
        mcp.run()

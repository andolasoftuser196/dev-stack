# Security policy

## Reporting a vulnerability

Please report security issues privately, not as a public issue.

- Preferred: open a [private security advisory](https://github.com/andolasoftuser196/dev-stack/security/advisories/new)
  on GitHub.
- Alternatively, email `andolasoft.user196@gmail.com`.

Include what you did, what happened, and what you expected. A minimal
reproduction - the `config/stack.yml` and the commands - is worth more than a
long description. If the issue involves the agent sandbox, say which egress mode
was in effect (`--egress full` disables the primary boundary by design).

You should get an acknowledgement within a few days. There is no bounty. If the
report is valid you will be credited in the advisory unless you ask not to be.

## What this project is

ssmd is a **local development** toolkit. It stands up a Docker environment on a
developer machine: a web runtime, a database, a cache, a mail catcher, a front
proxy with a locally-trusted CA, and optionally a sandboxed container for a
coding agent.

It is **not hardened for production or for multi-tenant use**, and it should not
be exposed to an untrusted network. The services it starts are development
services with development defaults: an unauthenticated mail catcher, a database
reachable from the host, a proxy holding a CA whose private key sits in `data/`.

That said, the boundaries it *does* claim are meant to be real, and a gap
between what the docs claim and what the code does is a bug worth reporting.

## In scope

Reports are most useful where a documented boundary does not hold:

- **The no-egress network.** `agent/` and `docker-compose.instance.yml` put an
  agent sandbox on a Docker network with `internal: true`. A way out of that
  network other than the allowlist proxy is in scope.
- **The egress allowlist.** `policy/allow-hosts.txt` and the proxy in
  `agent/egress/`. Reaching a host that is not on the list is in scope.
- **The worktree boundary.** An agent sandbox mounts its own worktree and not
  the human's checkout. A path that lets a sandbox write outside its worktree,
  or read the developer's checkout, is in scope.
- **The policy layer.** `policy/denied-commands.tsv`, `policy/denied-paths.tsv`
  and `lib/policy.sh`. A command that should be refused and is not - in
  particular anything that destroys data without a snapshot - is in scope.
- **Destructive-operation guards.** `ssmd test` refusing a non-disposable database
  name, and `lib/db.sh` snapshotting before every destructive operation and
  aborting if the snapshot fails. A bypass of either is in scope.
- **Non-root containers.** No image bakes in a UID and `user:` comes from
  `HOST_UID`/`HOST_GID`. A path to root inside a container, or to writing host
  files as root, is in scope.
- **Secret handling.** ssmd keeps secrets in `.env`, never in the config database,
  and `.gitignore` excludes `.env`, `config/ssmd.db` and all of `data/`. A secret
  leaking into the database, the audit log, `ssmd describe`, `ssmd doctor` output or
  a committed file is in scope.
- **The MCP server and the Claude Code hooks.** `mcp/server.py` and
  `claude-plugin/hooks/`. A destructive operation reachable without an explicit
  `confirm=True`, or a hook that can be made to approve what it should deny, is
  in scope.

## Out of scope

These are known, documented properties rather than defects.
[`docs/AGENTS.md`](docs/AGENTS.md) explains each honestly:

- **`--egress full`.** It exists for convenience and gives the sandbox normal
  networking. The docs already say not to use it unattended.
- **Anything that does not speak HTTP proxy** - DNS tunnelling, raw sockets, git
  over SSH. These do not get out by another route; the *network* is the control,
  and the proxy only shapes what the allowed path can reach.
- **TLS not being inspected.** An allowed host that proxies elsewhere is a hole;
  keeping `allow-hosts.txt` short is the mitigation.
- **A pushing agent.** If you give an agent credentials it can commit and push.
  Your branch protection and the review gate are the control, not the container.
- **Prompt injection.** It is contained, not solved. An injected instruction
  ends at the sandbox's network and worktree; nothing stops the agent following
  one.
- **The Claude Code write-boundary hook.** It constrains Claude Code's tools and
  nothing else. A shell command that writes elsewhere is not stopped by it -
  the read-only mount is what stops that.
- **`ssmd agent diff` returning a verdict rather than refusing.** The review gate
  holds; it does not block. That is deliberate - see `docs/AGENTS.md`.
- **Development-grade defaults** in the services ssmd starts, on a machine where
  the developer already has root.
- Vulnerabilities in upstream images or language dependencies. Report those
  upstream; if ssmd pins something outdated, a normal issue is the right venue.

## If an agent misbehaves

Stop the run and treat it as a prompt-injection incident until proven otherwise.
`ssmd agent audit` and `data/state/agent-tools.jsonl` record what was attempted and
what was refused, which is where the reconstruction starts. The procedure is at
the end of [`docs/AGENTS.md`](docs/AGENTS.md).

## Supported versions

ssmd is developed on `main`, and fixes land there. There are no maintained release
branches.

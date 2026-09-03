# dx - a generic, AI-native development stack

One Docker environment that works the same way for a Laravel app, a CakePHP app,
a Next.js app, a Django service and a Go service - and that treats coding agents
as a supported kind of user rather than an afterthought.

[![CI](https://github.com/andolasoftuser196/dev-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/andolasoftuser196/dev-stack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Try it with no project of your own - a runnable demo app ships for every
runtime:

```bash
git clone https://github.com/andolasoftuser196/dev-stack.git dev-stack && cd dev-stack
cp examples/runtimes/go-service.stack.yml config/stack.yml
./dx up core && ./dx urls
```

Point it at a real project instead:

```bash
./dx init --into /path/to/your/project    # detect the project, scaffold a stack
cd /path/to/your/project/dev-stack
./dx up && ./dx urls
```

---

## What it is

A single `dx` script over a profile-gated `docker-compose.yml`, driven entirely
by configuration held in SQLite. **No image tag, port, timeout, threshold or
pattern is written in code** - if a value appears in a script or a compose file,
it is a bug. Add a language by adding a directory under `runtimes/`; never by
editing `dx`.

```
dev-stack/
  dx                          the only entry point
  config/dx.db                the config store (SQLite; not committed)
  config/defaults.yml         toolkit defaults      seed -> scope `default`
  config/stack.yml            this project          seed -> scope `stack`
  config/hosts.yml            per-machine profiles  seed -> scope `host:<n>`
  config/schema.sql           config + history + instances + leases + audit
  .env                        BOOTSTRAP ONLY: DX_DB, DX_HOST, secrets
  docker-compose.yml          base stack, every value interpolated
  docker-compose.instance.yml one worktree or agent instance
  lib/sqlite.sh lib/config.sh the config layer
  lib/                        core, db, instance, worktree, agent, policy, doctor
  runtimes/{frankenphp,node,python,go}/   everything language-specific
  caddy/proxy/                front proxy: TLS, hostname routing, local CA
  policy/                     what an agent may do, and what needs a human
  agent/{sandbox,egress}/     the container an agent runs in, and its only way out
  claude-plugin/              skills, commands, subagent, hooks, MCP for Claude Code
  mcp/server.py               dx exposed as MCP tools
  scaffold/                   dx init - the only part that needs Python
  demo-apps/                  one runnable app per runtime, so dx up works now
  examples/runtimes/          one stack config per runtime, pointing at them
  tests/                      602 assertions; tests/run
  docs/                       ARCHITECTURE, AGENTS, RUNTIMES, WORKTREES
```

## The command surface

```
Lifecycle     up [preset]  down  nuke  restart  recreate <svc>  build
Look at it    status  urls  describe  logs  preflight  doctor  verify
Work in it    sh  exec  run  deps  test  lint  repl  <runtime verbs>
Data          db  db:query  db:migrate  db:snapshot  db:restore  db:import  db:drop
Parallel      wt add|ls|up|stop|rm|logs|sh|exec|verify
Agents        agent spawn|ls|attach|run|verify|diff|rm|reap|policy|audit
Odds & ends   browse  ca-cert  debug  fix-perms  mcp:install  completion
```

`dx artisan`, `dx cake`, `dx npm`, `dx manage`, `dx go` and the rest come from
the runtime module - `dx describe` lists what this project has.

## Configuration

Everything lives in a SQLite database, resolved from three layers:

```
host:<DX_HOST>   config/hosts.yml      this machine     highest priority
stack            config/stack.yml      this project
default           config/defaults.yml   the toolkit      lowest
```

```bash
dx config list [prefix]     every effective value, and which layer it came from
dx config get <key>         one value
dx config set <key> <v>     change it now - no file edit, no restart
dx config explain <key>     why this value is what it is, layer by layer
dx config history [key]     what changed, when, and who changed it
dx config export            runtime changes not yet written back to the seeds
```

The YAML files are **seeds**, not the runtime source of truth: they exist so
configuration is diffable and committable. The database is what dx reads, which
is what makes `dx config set` work from a script or over MCP without a YAML
round-trip, and what gives every change an actor and a timestamp.

`.env` is **not** a configuration file. It holds two bootstrap values and any
secrets:

```
DX_DB=config/dx.db     where the store is        (optional)
DX_HOST=local          which host profile        (a selector, not a setting)
GITHUB_TOKEN=...       secrets, never in the database
```

A flat `.stack.env` cache sits on top, rebuilt whenever the database or a seed
changes, so the common path never opens SQLite and `dx` stays fast.

## Three read-only commands, three questions

| | Question | When |
|---|---|---|
| `dx preflight` | Will `dx up` work on this machine? | `dx up` failed non-obviously |
| `dx doctor` | Does reality match what dx believes? | Something drifted |
| `dx verify` | Is the app working **right now**? | After every change |

Merging them would produce a command too slow to run casually and too vague to
act on. `dx doctor` never auto-fixes: an auto-fixing doctor is one you stop
trusting, because you can no longer tell what it changed while you read its
output.

`dx verify` is the one that earns its keep. Six checks, and the last is **new
error lines in the log since the last verify** - which answers "did what I just
do break something", and nothing else does.

## Several branches at once

```bash
./dx wt add feature/billing
#   -> worktree     ../worktrees/feature-billing
#   -> database     app_dev_feature_billing   (seeded from the latest snapshot)
#   -> redis db     3                         (own logical db + key prefix)
#   -> bucket       feature-billing
#   -> url          https://feature-billing.app.test/
```

Instances share one database *server*, cache and mail catcher - not one database.
That sharing is the whole trick: per-branch stacks that each run their own MySQL
stop being usable at three concurrent branches, because the memory is gone.

Redis's logical databases are the real ceiling - the pool is
`instances.redis_db_min..max` in config, 1–15 by default, because the base stack
owns 0. A `UNIQUE` constraint on the column enforces it rather than a comment.
`dx wt ls` shows what is allocated.

## Agent sandboxes

```bash
./dx agent spawn feature/billing --owner claude --ttl 4h
./dx agent attach billing        # a shell inside the sandbox
./dx agent verify billing        # does it still work?
./dx agent diff billing          # what changed, and can it land unattended?
```

A worktree instance plus a container the agent runs **inside**:

| Boundary | Mechanism |
|---|---|
| Network | a Docker network with `internal: true` - no gateway, DNS for outside names does not resolve. The only way out is an allowlist proxy. |
| Filesystem | the worktree is the only writable path into the repo. **The human's checkout is not mounted.** |
| Resources | cpus, memory, pids capped. Exit 137 means the memory cap, not a test failure. |
| Privileges | `no-new-privileges`, `cap_drop: ALL` plus four. |
| Review | `dx agent diff` evaluates the change against denied paths and size caps. |

The review gate **never blocks the work**. A change touching a migration is
often exactly right; it just must not land unattended. A gate that refused to
produce the change would throw away correct fixes for touching a file - which is
the failure mode the design exists to avoid.

See [docs/AGENTS.md](docs/AGENTS.md) for what the isolation does and does not buy.

## The AI-native part

Four layers, each doing something the others cannot:

1. **A Claude Code plugin** (`claude-plugin/`) - four skills, six slash commands,
   a read-only `stack-doctor` subagent, and hooks. Installed once; the knowledge
   loads automatically rather than living in a CLAUDE.md someone forgets to read.

2. **Guardrail hooks** - `PreToolUse` refuses `docker compose`, a bare test
   runner, a lockfile-rewriting install, and (inside a sandbox) any write outside
   the worktree. Every denial names the alternative, because a guard that only
   says "denied" gets worked around.

3. **An MCP server** (`mcp/server.py`) - dx as typed tools with docstrings the
   model reads before calling. Destructive operations require an explicit
   `confirm=True`, so an ambiguous prompt cannot become a dropped database.

4. **A feedback loop** - `/healthz` answered by the web server (not the
   framework), structured JSON logs, Mailpit, a watchable browser at
   `https://vnc.<domain>/`, and `dx verify` to tie them together. An agent that
   can check its own work is worth more than one that is merely constrained.

```bash
./dx mcp:install          # register the MCP server
claude plugin install ./dev-stack/claude-plugin --scope project
```

## Prior art, and what was taken from it

| Source | Taken |
|---|---|
| DDEV | one CLI over everything; `describe`; snapshots as a first-class verb; add-ons as directories, not core edits |
| VS Code Dev Containers | the lifecycle-hook split - `postCreate` (once) vs `postStart` (every boot) is the difference between a 40-second and a 4-second boot |
| Lando | declarative per-project config as the source of truth |
| Docker Compose | profiles, which is what lets one file serve every runtime/service combination |
| `git config` layering | scoped configuration with an `explain` that says which layer won |
| Dagger `container-use`, agent sandbox tooling | per-agent containerised worktrees; the isolated network as the real boundary |
| Hand-rolled `up.sh` drivers | the single-entrypoint shape, preset→profile mapping, a Caddy front proxy owning the local CA, per-branch worktree instances, and a preflight that names the fix |

## Requirements

Docker with the compose v2 plugin, bash, git. That is the whole list for daily
use. `dx init` additionally wants python3 with jinja2 - and only `dx init`.

Linux or macOS. On Windows, WSL2 with the repository on the ext4 filesystem: a
bind mount from `/mnt/c` makes every file operation 10–50× slower and breaks
inotify, so nothing hot-reloads.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - how the pieces fit, and why
- [docs/AGENTS.md](docs/AGENTS.md) - the sandbox threat model, honestly
- [docs/RUNTIMES.md](docs/RUNTIMES.md) - adding a language
- [docs/WORKTREES.md](docs/WORKTREES.md) - parallel instances and their limits
- [CLAUDE.md](CLAUDE.md) - guidance for Claude Code working in this repo

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the
setup, the test commands, the five rules that shape every change, and what
"complete" means for a new runtime - which is the contribution the design is
built to accept.

Security issues go through [SECURITY.md](SECURITY.md), not a public issue.
Participation is under the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) - Copyright (c) 2026 Siba Maharana.

dx is a **local development** toolkit. It is not hardened for production or for
multi-tenant use, and the services it starts are development services with
development defaults. [SECURITY.md](SECURITY.md) says which boundaries it does
claim, and [docs/AGENTS.md](docs/AGENTS.md) says what the agent sandbox buys and
what it does not.

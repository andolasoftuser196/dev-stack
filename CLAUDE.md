# CLAUDE.md - working on the ssmd toolkit itself

Guidance for Claude Code when the task is changing **this repository**. For
working *inside* a ssmd stack on some other project, the plugin's
`dev-stack-ops` skill is the right reference; this file is about the toolkit.

## What this is

A generic development environment: one `ssmd` bash script over a profile-gated
compose file, driven entirely by configuration in a SQLite store, with
language-specific behaviour isolated into `runtimes/<kind>/`.

When you are unsure whether a behaviour is deliberate, assume it is. Most of the
sharp edges here are scar tissue, and the comment above the code says what went
wrong and why the obvious alternative is worse.

## The constraints that shape everything

**No configuration value appears in code.** Not an image tag, not a port, not a
timeout, not a threshold, not a glob pattern. If you are about to write a literal
in `ssmd`, `lib/`, a compose file or a Dockerfile, it belongs in
`config/defaults.yml` and you read it with `_cfg`. The audit that motivated this
found 73 such literals across eight categories; they are all gone, and the way to
keep them gone is to treat a new one as a bug rather than a shortcut.

Legitimate exceptions, and only these: a value that is genuinely optional and
empty (`runtime.packages`, `hooks.preDown`), and the fallbacks in
`mcp/server.py` that let a fresh container answer before the cache exists.

**`ssmd` runs on bash, docker, git and sqlite3.** SQLite is the one dependency the
config store adds, and `lib/sqlite.sh` softens it with three backends - the
`sqlite3` CLI, python3, or a container - picked once per invocation. What makes
it affordable is the `.stack.env` cache: configuration is resolved once and every
subsequent `ssmd` reads a flat file. **That cache is not an optimisation to remove
later**; it is what keeps ssmd fast and what keeps it usable when things are broken.

`ssmd init` additionally needs python with jinja2, and it happens once.

The seed files are read by `lib/yaml.awk` - a deliberately partial YAML reader
for the fixed subset the schema documents, with two output modes (shell variables
for the cache, dotted keys for the importer). Do not replace it with a real
parser unless you are also willing to add the dependency.

**Language-specific behaviour goes in `runtimes/<kind>/`, never in `ssmd` or
`lib/`.** The contract is `runtimes/_contract.md`. Adding PHP 7.2, Bun or Elixir
must be adding a directory. The moment a `case "$STACK_RUNTIME_KIND"` appears in
`ssmd`, the seam is gone - and it went first in every stack this replaces.

There are two deliberate exceptions, both in `lib/core.sh`, both defaulting a
value rather than branching behaviour (`SSMD_APP_PORT`, the image tag). If you add
a third, it is probably a runtime-module concern.

**Everything a service needs comes from config, not from editing compose.**
`docker-compose.yml` is generic across every runtime and service combination and
contains no literals at all. A project-specific edit there is wrong for the next
project; change `config/stack.yml`, or `ssmd config set`.

## Where things live

| Concern | File |
|---|---|
| the config store, and the only SQL in the toolkit | `lib/sqlite.sh`, `lib/config.sh` |
| the schema (config, history, instances, leases, audit) | `config/schema.sql` |
| toolkit defaults - every image, port, timeout, threshold | `config/defaults.yml` |
| this project | `config/stack.yml` |
| per-machine profiles | `config/hosts.yml` |
| bootstrap, compose plumbing, output, audit | `lib/core.sh` |
| the seed-file reader (two output modes) | `lib/yaml.awk` |
| database operations, engine-agnostic | `lib/db.sh` |
| instance registry, leases, routes, worktrees | `lib/instance.sh` |
| `ssmd wt` | `lib/worktree.sh` |
| `ssmd agent` | `lib/agent.sh` |
| the policy evaluator, shared with the hooks | `lib/policy.sh` |
| preflight / doctor / verify / status | `lib/doctor.sh` |
| per-language everything | `runtimes/<kind>/` |
| what an agent may do | `policy/*.tsv`, `policy/policy.yml` |
| Claude Code integration | `claude-plugin/` |
| ssmd as MCP tools | `mcp/server.py` |

## Invariants - do not break these without saying so

**`/healthz` is answered by the web server, never by the framework.** Every
runtime's `serve.conf` does this. If healthz routed through the application, a
syntax error would turn the healthcheck red, and compose would restart the
container you are actively debugging while its logs scroll away.

**Destructive database operations snapshot first, and abort if the snapshot
fails.** `lib/db.sh`. Leaving a database intact is always recoverable. Do not
"improve" this by making the snapshot best-effort.

**`ssmd test` refuses a non-disposable database name.** Both the runtime modules
and the policy hooks enforce it, independently. That redundancy is deliberate:
one is bypassed by editing a shell command, the other by editing a policy file,
and both would have to happen.

**Containers never run as root, and no image bakes in a UID.** `user:` is set
from `HOST_UID`/`HOST_GID` at runtime, and the compose file uses `${HOST_UID:?}`
so a stray `docker compose up` fails loudly rather than quietly running as root.

**The `no-egress` network has `internal: true`.** Every isolation claim in
`docs/AGENTS.md` rests on it. It is a kernel property, not a rule anything has to
remember to apply.

**The review gate holds; it does not block.** `ssmd agent diff` returns a verdict
and never refuses to produce work. A gate that refused would throw away correct
changes for touching a migration, and would be switched off within a month.
The *prevention* rules (`policy/denied-commands.tsv`, enforced by hooks) are the
ones that block, and they are for actions with no safe version.

**`profiles.all` in `config/defaults.yml` must list every profile that exists in
any compose file.** `down`, `nuke` and `recreate` enable all of them; a profile
missing there becomes a container `ssmd down` silently leaves running.

**A project command runs through `rt_exec`, never `docker exec` directly.**
`docker exec` starts a process that never ran the entrypoint, so whatever the
entrypoint set up — the python virtualenv, most obviously — is absent. Hooks,
`ssmd run`, `ssmd exec` and the per-instance equivalents all go through it.

**No non-interactive path uses a login shell.** `/etc/profile` resets `PATH` on
Debian and drops the language toolchain. `ssmd sh` is the one exception, because
it is interactive and a profile banner is the point there.

**No service is addressed as `app`.** Compose gives every service the alias of
its service name, and the base stack and every instance all call theirs `app` -
so the name round-robins across all of them. The base stack answers to `main`,
an instance to its slug, and both carry that alias on *both* networks. Fixing
one network and not the other is how this shipped the first time.

**An instance gets every runtime setting the base stack gets.** Anything added
to the app service's environment in `docker-compose.yml` must be added to the
instance overlay too, or a config change applies to main and to nothing else.

**Row-returning SQL is separated by `SSMD_FS` (U+001F), never a tab.** Tab is IFS
whitespace, so bash's `read` collapses runs of it and drops empty columns -
which shifts every field after the gap. That bug reached the history output
before it was caught, and it would have been far worse in the registry.

## Working on it

```bash
bash -n ssmd lib/*.sh runtimes/*/commands.sh   # syntax
awk -v mode=dotted -f lib/yaml.awk config/defaults.yml   # what a seed imports as
./ssmd config list                             # what actually resolved
./ssmd config explain <key>                    # and why
./ssmd describe                                # does it load?
./ssmd preflight                               # does the host check work?
docker compose -f docker-compose.yml config  # does compose interpolate?
```

After editing a seed, nothing needs doing: the next `ssmd` re-imports it (keyed on
mtime) and rebuilds the cache. To force it: `ssmd config import`.

### The test suite

```bash
tests/run                  # unit + python - fast, no docker daemon
tests/run --integration    # also end-to-end against real containers
tests/run unit/test_config # one file
ssmd selftest
```

Run it before and after any change to `lib/`, `config/defaults.yml` or the
compose files. It is fast enough to run on every save and it has already caught
six real bugs - `tests/README.md` lists them, and they are worth reading before
you decide a test is unnecessary.

Every test gets a throwaway copy of the toolkit with its own config database, so
nothing touches your own stack. Add a test whenever you fix a bug: the ones that
exist are all regressions.

Two audits worth re-running after any change:

```bash
# no literal image tags, ports or tuning numbers outside config/
grep -rnE '^\s*image:' docker-compose*.yml | grep -v '\$\{'
grep -rnE '\b(3306|5432|6379|8025|9000)\b' ssmd lib/*.sh docker-compose*.yml \
  | grep -vE '\$\{|\{\$|^\S+:[0-9]+:\s*#'

# no ${STACK_*:-fallback} masking a missing config key
grep -rnE '\$\{STACK_[A-Z_]+:-' ssmd lib/*.sh runtimes/*/commands.sh
```

## Style

Match what is here. Comments explain **why**, and specifically why the obvious
alternative is wrong - that is what makes them survive a refactor. A comment
restating the code is worse than none.

Error messages name the fix. `die "port 80 in use"` is half a message; the other
half is which file to change. Every denial in `policy/*.tsv` carries a reason
column for the same reason.

Keep `README.md` and the plugin skills honest. They document real failure modes,
and a stale line in either costs more than a missing one.

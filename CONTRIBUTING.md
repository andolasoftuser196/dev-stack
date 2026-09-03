# Contributing to dx

Thanks for looking. dx is a small toolkit with strong opinions, and most of
those opinions are scar tissue - a comment above the code usually says what went
wrong and why the obvious alternative is worse. Read the comment before changing
the line.

## Getting set up

```bash
git clone https://github.com/andolasoftuser196/dev-stack.git dev-stack
cd dev-stack
./dx describe          # does the config layer load?
./dx preflight         # does this machine satisfy the host checks?
tests/run              # unit + python - no docker daemon needed
```

Daily use needs docker with the compose v2 plugin, bash, git and sqlite3.
`dx init` additionally needs python3 with jinja2, and only `dx init`.
The integration tier needs a running docker daemon and takes a few minutes.

To try it end to end without a project of your own:

```bash
cp examples/runtimes/go-service.stack.yml config/stack.yml
./dx up core && ./dx urls
```

## The five rules that shape every change

These are not style preferences. Each of them was a bug first.

**1. No configuration value appears in code.** Not an image tag, not a port, not
a timeout, not a threshold, not a glob. If you are about to write a literal into
`dx`, `lib/`, a compose file or a Dockerfile, it belongs in `config/defaults.yml`
and you read it back with `_cfg`. An audit found 73 such literals across eight
categories; they are gone, and a new one is treated as a bug rather than a
shortcut. The only exceptions are values that are genuinely optional and empty
(`runtime.packages`, `hooks.preDown`) and the fallbacks in `mcp/server.py` that
let a fresh container answer before the cache exists.

**2. Language-specific behaviour lives in `runtimes/<kind>/`.** Adding PHP 7.2,
Bun or Elixir must mean adding a directory - see `runtimes/_contract.md`. The
moment a `case "$STACK_RUNTIME_KIND"` appears in `dx` or `lib/`, the seam is
gone, and it went first in every stack this replaces. Two deliberate exceptions
exist in `lib/core.sh`; both default a value rather than branch on behaviour.

**3. Everything a service needs comes from config, not from editing compose.**
`docker-compose.yml` is generic across every runtime and service combination and
contains no literals. A project-specific edit there is wrong for the next
project - change `config/stack.yml`, or use `dx config set`.

**4. Dependencies stay at bash, docker, git and sqlite3.** The `.stack.env`
cache is what keeps dx fast and what keeps it usable when things are broken; it
is not an optimisation to remove later. `lib/yaml.awk` is a deliberately partial
YAML reader for the fixed subset the schema documents - do not replace it with a
real parser unless you are also willing to add the dependency.

**5. Comments explain why, and specifically why the obvious alternative is
wrong.** That is what makes them survive a refactor. A comment restating the
code is worse than none. Error messages name the fix: `die "port 80 in use"` is
half a message, and the other half is which file to change.

`CLAUDE.md` carries the full list of invariants - healthz answered by the web
server, snapshot-before-destroy, non-root containers, `internal: true` on the
no-egress network, the review gate that holds rather than blocks. Breaking one
of those is sometimes right, but say so explicitly in the pull request.

## Tests

```bash
tests/run                    # unit + python - fast, no docker daemon
tests/run --integration      # also end to end against real containers
tests/run unit/test_config   # one file
./dx selftest                # the same runner, through dx
```

Run the fast tiers before and after any change to `lib/`, `config/defaults.yml`
or the compose files. They are quick enough to run on every save and they have
already caught six real bugs - `tests/README.md` lists them, and they are worth
reading before you decide a test is unnecessary.

Every test gets a throwaway copy of the toolkit with its own config database, so
nothing touches your own stack.

**Add a test whenever you fix a bug.** Every test that exists is a regression
test for something that actually broke.

## Two audits to re-run

```bash
# no literal image tags, ports or tuning numbers outside config/
grep -rnE '^\s*image:' docker-compose*.yml | grep -v '\$\{'
grep -rnE '\b(3306|5432|6379|8025|9000)\b' dx lib/*.sh docker-compose*.yml \
  | grep -vE '\$\{|\{\$|^\S+:[0-9]+:\s*#'

# no ${STACK_*:-fallback} masking a missing config key
grep -rnE '\$\{STACK_[A-Z_]+:-' dx lib/*.sh runtimes/*/commands.sh
```

The first two must come back empty. The third has exactly two legitimate hits -
`STACK_HOOKS_PREDOWN` (hooks are optional and legitimately empty) and
`STACK_REPO_GIT_ROOT` (documented as defaulting to `repo.root`) - and CI exempts
those two by name. Any third hit is a key that should exist in
`config/defaults.yml`; adding a fallback instead gives one value two sources of
truth, and they drift.

## Syntax and shape checks

```bash
bash -n dx lib/*.sh runtimes/*/commands.sh          # syntax
awk -v mode=dotted -f lib/yaml.awk config/defaults.yml   # what a seed imports as
./dx config list                                     # what actually resolved
./dx config explain <key>                            # and why
docker compose -f docker-compose.yml config          # does compose interpolate?
```

After editing a seed nothing needs doing - the next `dx` re-imports it, keyed on
mtime, and rebuilds the cache. To force it: `dx config import`.

## Adding a runtime

This is the contribution the design is built to accept. Read
`runtimes/_contract.md`, copy the closest existing directory, and provide
`Dockerfile`, `entrypoint.sh`, `commands.sh` and (usually) `serve.conf`. A
runtime is complete when:

- `runtime_images.<kind>` exists in `config/defaults.yml`, with `{version}`
  substituted rather than a tag written into the `FROM` line
- the image bakes in no UID, and writes only under `/dx/cache`
- `entrypoint.sh` answers `$DX_HEALTHZ` **from the web server**, not the
  framework, and handles the `serve`, `queue`, `scheduler` and `idle` roles
- `dx test` refuses a non-disposable database name
- a demo app lands in `demo-apps/<name>/` and a stack config in
  `examples/runtimes/<kind>-<name>.stack.yml`, so `dx up` works with no project
- `tests/unit/test_runtimes.sh` and `tests/integration/test_apps.sh` cover it

## Pull requests

- Branch from `main`; keep one concern per pull request.
- Say what broke, not only what changed. If the change is a fix, the commit
  message should describe the failure mode.
- Note explicitly if you touched an invariant, a policy file under `policy/`, or
  anything in `agent/` - those get read closely, because they are what the
  isolation claims in `docs/AGENTS.md` rest on.
- Keep `README.md` and the plugin skills honest. They document real failure
  modes, and a stale line in either costs more than a missing one.
- CI runs the fast tiers, the audits and `bash -n` on every push. Integration
  runs on `main` and on demand.

## Reporting bugs

Open an issue with the output of `./dx doctor` and `./dx describe`. Both are
read-only and neither prints secrets. If it involves a container, `./dx logs`
and the runtime kind and version help most.

Security issues go to `SECURITY.md` instead - please do not open a public issue
for those.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

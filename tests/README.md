# Tests

```bash
tests/run                  # unit + python - fast, no docker daemon needed
tests/run --integration    # also the end-to-end tier - real containers, minutes
tests/run unit/test_yaml   # one file
dx selftest                # the same runner, through dx
```

Exit status is zero only when every assertion passed.

## Tiers

| Tier | Needs | Time | Covers |
|---|---|---|---|
| `tests/unit/` | bash, awk, sqlite3 (docker CLI for compose parsing) | ~2 min | every pure function and every config path |
| `tests/python/` | python3 stdlib only | ~3 s | hooks, MCP server, scaffolder |
| `tests/integration/` | a running docker daemon | ~5 min | build, serve, route, isolate, tear down |

Nothing outside the integration tier starts a container, and nothing at all
touches your own dev-stack: each test gets a throwaway copy of the toolkit with
its own config database (`mk_sandbox` in `tests/lib.sh`).

## Why a hand-rolled harness

`tests/lib.sh` is about 120 lines and depends on nothing. The alternative is
bats, and "install bats first" is a poor answer on the machine where something
is already broken - which is exactly the machine these tests need to run on.
The Python tiers use stdlib `unittest` for the same reason.

## What each file covers

| File | Under test |
|---|---|
| `unit/test_yaml.sh` | the seed reader: both output modes, quoting, comments, and that every malformed input *warns* rather than silently yielding an empty value |
| `unit/test_config.sh` | layering (`host` > `stack` > `default`), import and re-import on mtime, history, cache invalidation, quoting round-trips, both SQLite backends agreeing |
| `unit/test_core.sh` | derivation: port offsets stable and distinct, engine selection, per-runtime inner ports, presets read from config rather than code |
| `unit/test_db_safety.sh` | the disposable and test-database patterns - the rules standing between a typo and a lost database |
| `unit/test_instance.sh` | registry CRUD, Redis allocation and its ceiling, reserved slugs, leases, route files |
| `unit/test_policy.sh` | the command guard, glob matching, and that the review gate *holds without blocking* |
| `unit/test_compose.sh` | every runtime × database combination, every profile, every example, and that no literal survives in the compose files |
| `unit/test_runtimes.sh` | `runtimes/_contract.md` conformance for all four modules |
| `python/test_hooks.py` | the JSON contract, POSIX-regex translation, glob semantics, sandbox confinement |
| `python/test_mcp.py` | config reading, truncation, refusals, timeout reporting |
| `python/test_scaffold.py` | detection for every runtime, and manifest precedence |
| `unit/test_apps.sh` | every demo app satisfies the contract in `demo-apps/README.md`, and every example points at one that exists |
| `integration/test_stack.sh` | the whole thing, against Docker |
| `integration/test_apps.sh` | boots each demo app for real, asks it the same question, and checks that the table its migration claims to create is actually there. `DX_TEST_APPS="go express"` limits it while iterating |

## Regressions these were written for

Every one of these was a real bug, found by writing the test:

- **`instance_load` returned its own SQL string.** Nested single quotes inside a
  `printf` format mangled the query when the registry moved into SQLite. Nothing
  that used an instance had worked since.
- **`PRAGMA foreign_keys` is per *connection*.** Setting it in `schema.sql`
  applied only to the connection that ran the schema, so `ON DELETE CASCADE`
  never fired and removed instances left their leases behind.
- **`PRAGMA busy_timeout=N` returns a row.** Fixing the above with `-cmd`
  prefixed `5000` to the result of every query in the toolkit.
- **Tab is IFS whitespace.** `read` collapses runs of it, so an empty column
  vanished and shifted every field after it. Row separators are U+001F now.
- **POSIX classes in Python's `re`.** `[[:space:]]` parses as a set of seven
  characters, so every command-guard rule matched nothing - the guard was
  installed, trusted, and denying nothing.
- **`database: none` produced a target port of 0**, which `docker compose
  config` rejects, so two examples could not be validated at all.
- **`https://app.<domain>` served whichever container answered first.** Compose
  gives every service the alias of its service name, and every instance also
  calls its app service `app` - so the proxy round-robined across the base stack
  and every running instance. The isolated-network half of this had been fixed;
  the more visible half had not.
- **Instances ran on the language's built-in defaults.** The instance overlay
  never passed the runtime settings the base stack gets, so a limit raised in
  config applied to main and nothing else - presenting as "it works on main but
  not on my branch".
- **`go install air@latest` broke the Go image.** `@latest` is `:latest` on an
  image tag wearing a hat: the tool resolved to a release requiring Go ≥ 1.26
  while the image had 1.23, and the build failed on a machine where nothing had
  changed. Tool versions are pinned in config now, and a test refuses any
  Dockerfile that reintroduces `@latest`.

### Found by booting the demo apps

Adding a runnable app per runtime and actually starting each one found a further
batch, every one of which would have hit a real project:

- **`sh -lc` in the runtime *entrypoints*.** The same login-shell bug as before,
  fixed in `commands.sh` but missed in the four entrypoints — so the serve loop
  lost the virtualenv and reported `flask: not found` inside a container where
  flask was demonstrably installed. The guard now covers both.
- **Lifecycle hooks bypassed the runtime environment.** `run_hooks` called
  `docker exec sh -c` directly, which never runs the entrypoint, so a Django
  migration failed with `ModuleNotFoundError: No module named 'django'`
  immediately after watching Django install. Hooks, `dx run` and `dx exec` all
  go through `rt_exec` now, which is part of the runtime contract.
- **`run_hooks` ate its own hook list.** `docker exec` reads stdin, and stdin was
  the here-string holding the remaining hooks — so only the first one ever ran.
  Third instance of that bug; the loops all read into an array first now.
- **`services.database: none` aborted config loading** with
  `STACK_DATABASE_NAME: unbound variable`, because such a project has no
  `database:` block at all.
- **`runtime.start_cmd` and its siblings were documented but never plumbed
  through.** Setting one silently did nothing.
- **An empty `DJANGO_SETTINGS_MODULE` is worse than an absent one.** Compose
  cannot omit a key conditionally, and `os.environ.setdefault` will not replace
  an empty string — so Django started with no settings at all. Overrides are
  passed under `DX_`-prefixed names and re-exported only when set.
- **A root-owned `/dx/cache` crash-looped the container** with no message beyond
  "restarting". Now it fails on the first boot with the command that fixes it.

### Found while closing the migration gap

- **dx never injected `DATABASE_URL`** — the name Doctrine, Prisma, SQLAlchemy,
  Diesel, Ecto and node-postgres all read. Derived from the connection details
  dx already knows, and rebuilt per instance rather than inherited: the base
  stack's URL names the base stack's database, and a migration run against it
  from an instance is precisely the accident per-instance databases exist to
  prevent.
- **CakePHP's console never needed a workaround.** `Router::reload()` — added to
  fix the web path — was the whole fix; the migration hook had been removed on
  the assumption the console needed skeleton state it did not.

## A note on writing these

Four assertions in this suite were first written as "the source must not contain
X" - against files whose comments *explain why they must not contain X*. Each one
passed while testing nothing, then failed for the wrong reason.

`code_only` in `tests/lib.sh` strips comments. Use it for any assertion about
what a source file does or does not contain; do not grep a file for a forbidden
token without it.

## Adding a test

Copy the shape of an existing file. A shell test is executable, sources
`../lib.sh`, and ends with `t_summary`:

```bash
#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "what this group is about"
assert_eq "expected" "$(thing_under_test)" "what should be true"

t_summary
```

Assertions: `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`,
`assert_match`, `assert_ok`, `assert_fail`, `assert_file`, `assert_no_file`,
plus `t_ok` / `t_fail` / `t_skip` for anything they do not cover.

Describe the behaviour, not the mechanism: `"a held change still exits zero -
the gate never blocks"` survives a refactor; `"policy_evaluate returns 0"` does
not.

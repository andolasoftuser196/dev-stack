# Runtime module contract

A runtime module teaches `dx` how to build, serve, and operate one language
stack. Adding PHP 7.2, Bun, Rust or Elixir means adding a directory here - never
editing `dx`, `lib/`, or `docker-compose.yml`.

That constraint is the point. A driver with the application's language welded
into it works fine until the first project that needs a second language, and then
the usual outcome is a compose file with twenty near-identical sidecar services
in it - because there was no seam to put them behind.

## Files

```
runtimes/<kind>/
  Dockerfile        # builds the image; must accept the build args below
  entrypoint.sh     # installed as /usr/local/bin/dx-entrypoint
  commands.sh       # sourced by dx; defines the rt_* functions below
  serve.conf        # optional: web-server config the entrypoint installs
```

## Dockerfile build args

| Arg | Meaning |
|---|---|
| `BASE_IMAGE` | the full base image, resolved from `runtime_images.<kind>` in config with `{version}` substituted. Never write a `FROM` tag literally - it would be a second place to bump a version, and the two drift. |
| `EXTRA_PACKAGES` | newline-separated `runtime.packages`, installed with the system package manager |

The image **must not** bake in a UID. Containers run as `${HOST_UID}:${HOST_GID}`
so that files written into the bind-mounted repo stay editable on the host, and
an image built for one developer's UID is useless to the next. Anything the
process needs to write must live under `/dx/cache` (a bind mount, created by dx)
or be world-writable in the image.

## entrypoint.sh

Installed as `dx-entrypoint`. Invoked as `dx-entrypoint <role>`, where role is:

| Role | Contract |
|---|---|
| `serve` (default) | Run the web server in the foreground on `$DX_PORT`. Must answer `$DX_HEALTHZ` with 200 **from the web server itself**, not the application framework. |
| `queue` | Run the background worker in the foreground. Exit non-zero if the runtime has no worker concept and one was requested. |
| `scheduler` | Run the periodic scheduler in the foreground. |
| `idle` | Sleep forever. Used by worktree instances that only need a shell. |

`$DX_HEALTHZ` answered by the web server is non-negotiable. A healthcheck that
routes through the framework goes red the moment you introduce a syntax error -
so compose restarts the container you are actively debugging, and the logs you
need scroll away.

### Environment the entrypoint receives

`DX_STACK`, `DX_DOMAIN`, `DX_RUNTIME`, `DX_FRAMEWORK`, `DX_DOCROOT`, `DX_PORT`,
`DX_HEALTHZ`, `DX_INSTANCE`, `DX_ROLE`, plus `DB_*`, `REDIS_*`, `MAIL_*`, `S3_*`.

`DX_INSTANCE` is `main` for the base stack and the slug for a worktree or agent
sandbox. Use it for anything that must not collide between instances - a cache
key prefix, a lock name, a log filename.

## commands.sh

Sourced into dx's shell, so it may use `log`, `die`, `dexec`, `compose`,
`container`, and every `STACK_*` variable. Define these:

| Function | Contract |
|---|---|
| `rt_display_name` | One line, human-readable. Shown by `dx describe`. |
| `rt_deps_install` | Install dependencies inside the app container. Called by the `postCreate` hook and `dx deps`. |
| `rt_deps_present` | Exit 0 if dependencies are already installed. Used to skip a slow reinstall. |
| `rt_migrate` | Apply schema migrations, or exit 0 if the runtime has none. |
| `rt_test [args...]` | Run the test suite **safely** - see below. |
| `rt_lint [args...]` | Run the formatter/linter. |
| `rt_repl` | Open an interactive language shell. |
| `rt_exec <service> <cmd>` | Run a command **in the environment the runtime needs**. See below. |
| `rt_dispatch <cmd> [args...]` | Handle runtime-specific verbs. Return 1 for anything unrecognised so dx can print its own error. |
| `rt_verbs` | Space-separated list of verbs `rt_dispatch` handles. Feeds `dx help` and shell completion. |

### `rt_exec` is not `docker exec`

`docker exec` starts a process that never ran the entrypoint, so anything the
entrypoint set up is missing from it. For python that is the virtualenv, and the
symptom is `ModuleNotFoundError` for a package that was demonstrably just
installed — because the install went into the venv and the command ran outside
it.

Every path that runs a *project* command goes through `rt_exec`: lifecycle
hooks, `dx run`, `dx exec`, and the per-instance equivalents. If a runtime needs
nothing special, it is one line:

```bash
rt_exec() { local svc="$1"; shift; dexec "$(container "$svc")" sh -c "$*"; }
```

Note `sh -c`, never `sh -lc`. A login shell sources `/etc/profile`, which on
Debian resets `PATH` unconditionally and drops whatever the image added.

### `rt_test` must be safe by construction

This is the one function with a hard requirement beyond "make it work". A test
suite that reads the *development* database connection and then truncates it is
not a hypothetical - a commented-out override in the suite's own configuration is
all it takes. `rt_test` must point the suite at a database whose name matches
the disposable pattern (`<db>_test`, or the per-instance sandbox database) and
must refuse to run if it cannot.

`dx test` never calls the framework's test runner directly, and
`policy/policy.yml` denies the agent from doing so either.

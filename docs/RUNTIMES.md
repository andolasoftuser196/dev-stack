# Adding a language

A runtime module teaches `dx` how to build, serve and operate one language stack.
Adding PHP 7.2, Bun, Rust or Elixir means adding a directory here - never editing
`dx`, `lib/` or `docker-compose.yml`.

That constraint is the point. A driver with the application's language welded
into it works fine until the first project that needs a second one, and the usual
outcome is twenty near-identical sidecar services in the compose file - because
there was no seam to put them behind.

The full contract is [`runtimes/_contract.md`](../runtimes/_contract.md). This
document is the walkthrough.

## Four files

```
runtimes/<kind>/
  Dockerfile      accepts RUNTIME_VERSION and EXTRA_PACKAGES
  serve.conf      the web-server config (Caddy)
  entrypoint.sh   installed as dx-entrypoint; roles serve|queue|scheduler|idle
  commands.sh     sourced by dx; defines the rt_* functions
```

## The shape every runtime shares

Caddy owns `$DX_PORT` and answers `$DX_HEALTHZ` itself. For `frankenphp` that is
free - Caddy *is* the runtime. For the others, Caddy reverse-proxies to the app
process on an inner `$DX_APP_PORT`.

That front layer is not decoration. It is what keeps healthz answering while the
application process is crash-looping, which is exactly when you need the
container to stay up so you can read its logs. Without it, compose restarts the
container you are actively debugging.

```
       :$DX_PORT                    127.0.0.1:$DX_APP_PORT
  ─────────────────►  Caddy  ─────────────────────────────►  node / uvicorn / air
                        │
                        └── /healthz  200, always
```

## The Dockerfile

- **Never bake in a UID.** Containers run as `${HOST_UID}:${HOST_GID}` so files
  written into the bind-mounted repo stay editable on the host, and an image
  built for one developer's UID is useless to the next.
- Redirect everything that wants `$HOME` to `/dx/cache`, which dx bind-mounts.
  The invoking UID has no `/etc/passwd` entry and therefore no home directory;
  the first tool that wants one otherwise fails with a confusing `EACCES`.
- Put the dependency cache there too. A fresh worktree instance installing from a
  warm cache takes seconds instead of minutes, and that difference decides
  whether people use instances at all.

```dockerfile
ENV HOME=/dx/cache/home \
    <PKG>_CACHE=/dx/cache/<pkg> \
    XDG_CONFIG_HOME=/dx/cache/config
RUN mkdir -p /dx/cache && chmod -R 777 /dx
```

## The entrypoint

Four roles. `serve` runs the web server in the foreground; `queue` and
`scheduler` run their loops; `idle` sleeps (used by instances that only need a
shell).

Two things every entrypoint should do:

**Install the stack CA.** `/dx/ca/root.crt` is mounted read-only. Each language
reads a different variable - `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`,
`CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`. Without it, server-side HTTPS to
`https://*.<domain>` fails with an unknown-authority error that reads like an
application bug.

**Restart the app process, not the container.** Loop around it and leave Caddy
running. A worker that exits because it hit its max-runtime is healthy, and
letting compose treat that as a crash makes the restart backoff grow until the
queue stops draining.

## commands.sh

Sourced into dx's shell, so it may use `log`, `die`, `dexec`, `container`,
`audit` and every `STACK_*` variable.

| Function | Contract |
|---|---|
| `rt_display_name` | one line, for `dx describe` |
| `rt_verbs` | space-separated verbs `rt_dispatch` handles; feeds help and completion |
| `rt_deps_present` | exit 0 if dependencies are installed |
| `rt_deps_install` | install them, **from the lockfile** |
| `rt_migrate` | apply migrations, or exit 0 |
| `rt_test` | the suite, **safely** - see below |
| `rt_lint`, `rt_repl` | formatter, language shell |
| `rt_dispatch` | runtime verbs; return 1 for anything unrecognised |
| `rt_doctor_notes` | project-shape warnings for `dx doctor` |

### `rt_deps_install` installs, it never updates

`composer install` not `update`; `npm ci` not `install`; `--frozen-lockfile`;
`go mod download` not `tidy`. A dev stack that silently rewrites a lockfile
produces a diff the developer did not ask for and did not read - and it is how a
compromised package version gets pulled onto a machine where nobody was watching.

### `rt_test` must be safe by construction

The one function with a hard requirement beyond "make it work".

A suite using a refresh-the-database trait reads whatever database the
configuration names and drops every table in it. If that configuration points at
the development database - and it does, more often than anyone expects, because
the test config's own override is frequently commented out - the suite destroys
the data the developer was working with.

`rt_test` must force the database to the disposable pattern **in the
environment**, so it is right even when the project's own test config is not, and
must refuse if the name it computed does not look disposable:

```bash
rt_test() {
    local test_db="${DB_NAME}_test"
    case "$test_db" in *_test|*_sandbox) ;; *) die "refusing: '$test_db' is not disposable" ;; esac
    db_create_database "$test_db"
    dexec -e DB_DATABASE="$test_db" -e APP_ENV=testing "$(container app)" sh -lc "<runner> $*"
}
```

## Wiring it up

1. Add the directory and the four files.
2. Add the inner-port default to the `case` in `lib/core.sh`'s `load_config`
   (the only place `dx` knows runtime names, and only to default a number).
3. Teach `scaffold/scaffold.py`'s `detect()` the manifest that identifies it.
4. Test:

```bash
./dx describe                # does the module load?
./dx build                   # does the image build?
./dx up core && ./dx verify  # does it serve, and does healthz answer?
```

## The four that ship

| Kind | Base | Serves | Hot reload | Inner port |
|---|---|---|---|---|
| `frankenphp` | `dunglas/frankenphp` | Caddy with PHP embedded | opcache revalidate | - |
| `node` | `node:*-slim` + Caddy | Caddy → node | the framework's dev server | 3000 |
| `python` | `python:*` + Caddy + uv | Caddy → uvicorn/runserver | the framework's reloader | 8000 |
| `go` | `golang:*` + Caddy + air | Caddy → the binary | `air` recompiles | 8080 |

Go's route sets `lb_try_duration 30s`, because a rebuild takes the upstream away
for a second or two - without it every save produces a 502 in the browser and a
red line in the log that looks like a crash.

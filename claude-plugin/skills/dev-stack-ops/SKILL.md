---
name: dev-stack-ops
description: Operate a dx development environment - start and stop it, run commands in it, read its logs, inspect its data, and check whether the app actually works. Use whenever a task involves running this project locally, and BEFORE reaching for raw docker, docker compose, or a framework CLI on the host.
---

# Working in a dx dev-stack

This project's local environment is driven by `dx`, a single script in the
`dev-stack/` directory. It wraps docker compose and knows things compose does
not: the host UID/GID the containers must run as, which profiles this project's
`stack.yml` implies, the derived port offset, and the post-start work.

**A raw `docker compose up` starts a subtly different stack.** It runs
everything as root, so the next file the app writes into the bind-mounted repo is
one you cannot edit. That failure surfaces hours later, nowhere near its cause.
This is the single most common way to lose an afternoon here.

## Orient yourself first

Run these before doing anything else in an unfamiliar stack:

```bash
./dx describe    # runtime, framework, services, the verbs this project has
./dx status      # what is running, and where it is
```

`dx describe` tells you whether to use `dx artisan`, `dx cake`, `dx manage` or
`dx go` - do not guess, and do not assume from file extensions.

## Tool order

Reach for these in order. Each one is faster and more reliable than the next.

1. **`./dx run <cmd>`** - anything the framework can answer. A REPL one-liner, a
   CLI command, `migrate:status`. This is almost always the right tool.
2. **`./dx db:query "<sql>"`** - anything about *data* rather than code. Faster
   than an ORM round-trip and the output is easier to read.
3. **`./dx logs <service> -f`** - before guessing at a cause. Filter it; an
   unfiltered log is mostly request noise.
4. **`./dx verify`** - after making a change. See below; this is the strongest
   signal available.
5. **Mailpit** at `https://mail.<domain>/` - to check mail the app sent. This
   beats asserting on a notifications table, which only tells you the app
   *intended* to send something.
6. **A browser**, last. It is the slowest and most fragile tool here. Use
   `./dx browse <url>` and watch it at `https://vnc.<domain>/`, and only when the
   task genuinely requires driving the UI.

## `dx verify` is the check that matters

```bash
./dx verify              # the main stack
./dx verify <slug>       # a worktree or agent instance
```

It checks six things in order, and the last one is the reason to run it: **new
error lines in the log since the last verify**. That answers "did what I just do
break something", which no amount of reading your own diff can.

A passing `dx verify` is evidence. "The tests pass" is weaker - the suite may not
cover the path you touched. "It looks right" is not evidence at all.

## Three read-only commands, three different questions

| Command | Question | When |
|---|---|---|
| `dx preflight` | Will `dx up` work on this machine? | `dx up` failed for a non-obvious reason |
| `dx doctor` | Does reality match what dx believes? | An instance is behaving oddly; after manual docker fiddling |
| `dx verify` | Is the app working right now? | After every change |

None of them modify anything. `dx doctor` in particular never auto-fixes - it
reports drift and leaves the decision to you.

## Configuration lives in two files

- **`stack.yml`** - what this project *is*: runtime, framework, services, routes,
  lifecycle hooks. Committed. Edit it and any `dx` command picks the change up
  automatically (it recompiles when the file is newer).
- **`.env`** - what *this machine* does: ports, bind address, secrets. Not
  committed.

If two developers would need different values, it goes in `.env`. If they need
the same value, it goes in `stack.yml`.

Do not edit `docker-compose.yml` to change what runs - set it in `stack.yml`.
The compose file is generic across every runtime and service combination, and a
project-specific edit there will be wrong for the next person.

## Things that will waste your time if you do not know them

**Process environment beats the app's `.env` file.** dx injects `DB_HOST`,
`DB_DATABASE` and the rest as container environment, and the runtimes are
configured so that process env wins. Editing the app's own `.env` to change a
connection does nothing. Edit `stack.yml` (or `dev-stack/.env`) and `dx restart`.

**Code changes need no restart; some things do.**
- Interpreted runtimes revalidate on every request - just save.
- The **queue worker** caches the booted framework: `dx recreate queue`.
- A **Caddyfile** edit: the proxy reloads on `dx wt`/`dx agent` operations, or
  `dx exec proxy caddy reload --config /etc/caddy/Caddyfile`.
- `php.prod.ini` locks opcache: `dx recreate app` after every edit.

**Never run the test suite outside `dx test`.** A suite that refreshes the schema
reads whatever database the config names and drops every table in it. `dx test`
creates and targets `<db>_test`, and refuses to run if the name it computed does
not look disposable. The policy hooks block the bare runner for this reason.

**Never run `composer update`, `npm install` or `go mod tidy`.** They rewrite a
lockfile, and that diff needs a human. `dx deps` does the frozen-lockfile install.

**Do not modify anything under `dev-stack/data/`.** That is runtime state:
database files, the local CA and its private key, container profiles, caches.

## Certificates

The stack has its own CA. Server-side HTTPS calls between containers already
trust it. If *your* browser or a host-side tool does not, run `./dx ca-cert` - it
prints the certificate path and how to trust it. Do not disable TLS verification
to work around it; that habit outlives the dev stack.

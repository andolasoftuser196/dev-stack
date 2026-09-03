# Architecture

How the pieces fit, and - more usefully - why each one is shaped the way it is.
Most of these decisions are reversals of something that did not work in a
previous generation of this kind of tooling.

## The one-paragraph version

`stack.yml` declares what a project is. `ssmd` compiles it to flat shell variables
and uses them to drive a single generic `docker-compose.yml` whose optional
services are all profile-gated. Everything language-specific lives in a runtime
module under `runtimes/`. A Caddy front proxy owns 80/443 and routes by hostname,
so the app, every branch instance and every agent sandbox get a real HTTPS URL
without any of them publishing a port.

## Configuration: two files, one question each

```
stack.yml   what this project IS      committed     runtime, services, routes, hooks
.env        what THIS MACHINE does    gitignored    ports, bind address, secrets
```

The test for where a setting belongs: *if two developers would need different
values, it goes in `.env`.* That rule is what makes `stack.yml` safe to commit,
and committing it is what makes a fresh checkout reproduce the environment.

`stack.yml` is compiled to `.stack.env` by `lib/yaml.awk` and cached, recompiling
whenever the source is newer.

### Why a partial YAML reader instead of yq or python

`ssmd` is what you reach for when the stack is already broken. Every runtime
dependency is one more way for it to be broken too, and "install yq first" is a
poor answer at that moment. `lib/yaml.awk` reads the fixed, shallow subset the
schema documents - two-space indent, scalars, inline and block lists - and warns
on stderr about anything outside it rather than silently producing an empty
value.

The cost is real: no anchors, no multi-line scalars, no maps inside lists. The
schema is designed around that, and `policy/*.tsv` exists because the reason
column *is* a map-inside-a-list and TSV expresses it better anyway.

## Ports: derived, not assigned

A hash of `name@domain` gives a stable offset in 100–999, applied to the database,
cache, storage, VNC and MCP ports. Same project, same ports forever; different
projects, near-certainly different ports. Nobody hand-allocates anything.

The proxy's 80/443 are deliberately **not** offset - a dev domain is only useful
without a port suffix in the URL - so two stacks wanting the proxy at once is a
genuine conflict, and `ssmd preflight` says so by name, distinguishing "your own
stack already holds it" from "a different stack does".

## Routing: one proxy, one CA, no published ports

```
        host :80/:443
             │
      ┌──────▼──────┐   local CA, TLS termination, routes by Host
      │    proxy    │
      └──┬───┬───┬──┘
         │   │   └──────────── import sites/*.caddy  (one per instance)
         │   └────────── mail. db. cache. s3. vnc. mcp.
         └── app.<domain>  →  app:80
```

Only the proxy publishes ports. The app and every instance listen internal-only,
and `reverse_proxy` preserves the original `Host` - which is what lets **one**
app-side config serve `app.<domain>`, `<slug>.<domain>` and `<agent>.<domain>`
with no per-instance web-server configuration at all.

Three details that each cost someone a day somewhere:

- **`flush_interval -1` on every route.** Without it, streamed downloads, SSE,
  websocket upgrades, Vite HMR and MCP's streamable-HTTP transport all appear to
  hang, and the symptom points nowhere near the proxy.
- **`import sites/*.caddy` needs `00-placeholder.caddy`.** A glob matching zero
  files is a hard error in Caddy, which would crash-loop the proxy on a fresh
  checkout - taking every instance down before anyone created one.
- **A catch-all `:80` block, last.** An address-only site is Caddy's
  lowest-priority match, so named vhosts still win, and `http://<host-ip>/`
  reaches the app with no DNS at all. That is what makes the stack usable in the
  five minutes before anyone edits a hosts file.

The proxy is the single CA owner. Its root is bind-mounted read-only into every
app container, so server-side HTTPS to `https://*.<domain>` validates instead of
failing with an unknown-authority error that reads like an application bug.

## `/healthz` is answered by the web server, never the framework

Every runtime's `serve.conf` answers healthz itself. This is the invariant that
makes debugging tractable:

| healthz | app request | means |
|---|---|---|
| 200 | 200 | fine |
| 200 | 5xx | **the container is fine; your code is broken** |
| fail | - | the container is broken |

If healthz routed through the framework, a syntax error would turn the
healthcheck red, compose would restart the container you are actively debugging,
and the logs you need would scroll away.

For `node`, `python` and `go` this is why a small Caddy sits in front of the app
process: it keeps healthz answering while the app is crash-looping, and it makes
all four runtimes behave identically.

## Profiles: one compose file for every combination

`stack.yml` says `database: postgres`; `ssmd` turns that into `--profile postgres`.
Compose cannot express a conditional, and generating a compose file per project
is the obvious alternative - it works, and it means every generated file is one
more thing that can drift from its template.

Profiles are the simpler answer. The cost is one rule that must be obeyed:
**`ALL_PROFILES` in `lib/core.sh` must list every profile in every compose file**,
because `down`, `nuke` and `recreate` enable all of them and a profile missing
from that list becomes a container `ssmd down` silently leaves running.

## Lifecycle hooks

Taken from the devcontainer spec, which got this right:

| Hook | When | Typical |
|---|---|---|
| `postCreate` | once, per created container | dependency install |
| `postStart` | every start | migrations |
| `preDown` | before stopping | best-effort |
| `postInstance` | once per worktree/agent instance | migrations |

The `postCreate`/`postStart` split is the difference between a 40-second boot and
a 4-second one. The marker lives in `data/state/`, keyed by container ID, rather
than inside the container - so a container rebuilt for an unrelated reason does
not re-run a ten-minute install.

`postCreate` and `postStart` failures are **fatal**. A stack that came up with
its migrations half-applied is worse than one that did not come up, because the
second kind is obvious.

## Instances

An instance is a git worktree + own database + own Redis logical database + own
bucket + a route, running as a separate compose project against the base stack's
backing services.

Sharing the backends is the whole trick. Per-branch stacks that each run their
own MySQL are what everyone builds first, and they stop being usable at three
concurrent branches because the memory is gone.

The registry is `data/state/instances.tsv` - a TSV, not SQLite. It is read by
shell, by python and by a human with `cat`; it diffs legibly; a corrupt line is
visible rather than needing a tool to inspect. The cost is no transactions,
handled with an `flock`, which is enough for a file one machine appends to.

**Redis has sixteen logical databases and the base stack owns 0.** Fifteen
concurrent instances is therefore a hard ceiling - not memory, not ports. Worth
knowing before planning for twenty branches at once.

## Agent sandboxes

An instance plus a container the agent runs inside, on the isolated network. See
[AGENTS.md](AGENTS.md) - the threat model belongs there, stated honestly, rather
than as a bullet list here.

## The AI-native layer

Four things, each doing something the others cannot:

**The Claude Code plugin** (`claude-plugin/`) puts the operating knowledge where
it loads automatically - four skills, six commands, a read-only `stack-doctor`
subagent - rather than in a CLAUDE.md that gets skimmed.

**Hooks** enforce what documentation cannot. `PreToolUse` on Bash refuses
`docker compose`, a bare test runner, and lockfile-rewriting installs; on
Edit/Write it confines sandbox writes and flags review-gate paths. Every denial
names the alternative, because a guard that only says "denied" gets worked
around. `SessionStart` injects the stack's actual state so the first three turns
are not spent rediscovering it. `Stop` notes when code changed and nothing
verified it.

The hooks are the one place that assumes python3 - the contract is JSON in, JSON
out, and parsing JSON in bash means depending on jq or hand-rolling a parser that
will eventually be wrong in a way that **fails open**. A guard that fails open is
worse than no guard, because it is trusted. (This bit us during development: the
first version used POSIX `[[:space:]]` patterns, which Python's `re` parses as
something else entirely and silently matched nothing.)

**The MCP server** (`mcp/server.py`) gives ssmd typed signatures and docstrings the
model reads before calling, instead of terminal output it has to parse.
Destructive operations require `confirm=True`, so an ambiguous prompt cannot
become a dropped database - the flag has to come from an explicit decision that
shows up in the transcript.

**The feedback loop** is the part that actually matters. Constraining an agent is
worth less than letting it check its own work: `/healthz`, structured JSON logs,
Mailpit, a watchable browser, `ssmd verify`'s error-diff-since-last-run, and
`ssmd agent diff`'s verdict. An agent that can tell whether it succeeded needs far
less supervision than one that cannot.

## Deliberate omissions

**No web control panel.** A browser UI over the same operations is genuinely
useful right up to the point where it becomes a second implementation of every
one of them, and then it drifts. The MCP server covers the case that motivates a
panel - driving the stack without a terminal - at a fraction of the surface.

**No generated per-project compose files.** Profiles cover it, and every
generated file is one more thing that drifts from its template.

**No dependency on a specific CI system, secret manager or cloud.** The stack
runs on a laptop and on a bare VM; anything beyond that is a project's own
concern.

---
name: debug-failing-request
description: Diagnose a failing HTTP request, a 500, a blank page, a hanging request, or a job that does not run, in a dx dev-stack. Use when something in the running app is broken and the cause is not yet known - before reading source code speculatively.
---

# Debugging a failing request in a dx stack

The cheapest diagnosis first. Most of these are answered in one command, and the
order below is roughly the order of how often each one turns out to be the cause.

## 0. Establish what is actually broken

```bash
./dx verify
```

It separates four failures that look identical from the browser:

| `dx verify` says | Means | Next |
|---|---|---|
| container not running | the process died | `dx logs app --tail 100` |
| healthz not 200 | the **web server** is unhealthy | config error, port conflict - `dx logs app` |
| healthz 200 but app returns 5xx | the **application** is broken | step 1 below |
| database unreachable *from the app* | networking, not the database | `dx doctor` |

That distinction is the whole reason healthz is answered by the web server rather
than the framework. A 200 from healthz and a 500 from the app is a precise
statement: the container is fine, your code is not.

## 1. Read the error, do not infer it

```bash
./dx logs app --tail 100
./dx exec app sh -lc 'tail -50 storage/logs/laravel.log'   # or the project's own log
```

If the MCP server is registered, `dx_errors(service="app", since="10m")` filters
to just error lines across every format the runtimes emit.

A blank page with nothing in the log is almost always one of:
- a fatal in a place the framework's handler cannot catch - check the **web
  server** log, not the application log;
- output buffering swallowing it - `dx exec app sh -lc 'php -i | grep output_buffering'`;
- the request never reaching the app at all - see step 3.

## 2. Is it the code or the data?

```bash
./dx db:query "SELECT COUNT(*) FROM <table>"
```

An empty database is the most common cause of a fresh stack 500ing, and it looks
exactly like a code bug. `dx verify` reports the table count for this reason.

## 3. Is the request even arriving?

```bash
./dx logs proxy --tail 50
```

If the proxy shows no entry, the request did not reach the stack: DNS is pointing
somewhere else, or you are on the wrong hostname. The proxy has a catch-all, so
`http://<host-ip>/` reaches the app with no DNS at all - try that to isolate it.

If the proxy shows a 502, the app container is down or still starting.

## 4. A hanging request

Almost always response buffering or a lock:
- The proxy sets `flush_interval -1` on every route, so streaming works. If you
  have added a route by hand without it, streamed responses will appear to hang.
- A queued job holding a row lock: `./dx logs queue --tail 50`.
- An outbound HTTP call from inside a container with no route: in an **agent
  sandbox** this is expected - the network is isolated, and anything not on the
  allowlist hangs until it times out. `dx agent policy` shows the allowlist.

## 5. A job that never runs

```bash
./dx logs queue --tail 100
./dx recreate queue        # the worker caches the booted framework
```

The worker boots the framework once and keeps it. Code changes do not reach it
until it is recreated - this is the single most common "my fix did not work" in
any queue-backed stack.

## 6. Only then, read the code

By this point you know the file and usually the line. Reading source before this
step means reading it without knowing what you are looking for.

## After the fix

```bash
./dx verify          # no new errors since the last run?
./dx test            # if the change is covered
```

`dx verify` compares against a stored marker, so run it *before* the change too
if you want a clean comparison - otherwise pre-existing errors count as new.

---
description: Read container logs, filtered to what matters
argument-hint: "[service] [pattern]"
allowed-tools: Bash(*/ssmd logs*), Bash(*/ssmd status*)
---

Run `./ssmd logs ${1:-app} --tail 200`.

If a second argument was given, filter the output to lines matching it.
Otherwise, if the log is long, filter to error-level lines yourself rather than
pasting two hundred lines of request noise - the runtimes emit structured JSON
logs, so `"level":"error"` is a reliable filter, alongside `fatal error`,
`uncaught`, `traceback` and `panic:`.

Quote the actual log lines. Do not paraphrase an error message.

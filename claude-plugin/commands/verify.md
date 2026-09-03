---
description: Check whether the app actually works right now, and report the evidence
argument-hint: "[instance-slug]"
allowed-tools: Bash(*/dx verify*), Bash(*/dx logs*), Bash(*/dx doctor*)
---

Run `./dx verify $1` (default instance: main).

Report the result honestly and specifically:

- If it passes, say so in one line.
- If it fails, name **which** of the six checks failed and what that
  distinguishes. In particular: healthz 200 with a failing app request means the
  container is fine and the application is broken; a database unreachable *from
  the app container* is a networking problem, not a down database.
- If it reports new error lines since the last verify, quote them.

Do not paper over a failure by re-running until it passes, and do not report
"verified" on the strength of the containers being up.

---
description: Start the dx dev-stack and report where everything is
argument-hint: "[core|default|tools|full]"
allowed-tools: Bash(*/dx up*), Bash(*/dx status*), Bash(*/dx urls*), Bash(*/dx preflight*)
---

Start this project's development environment.

Run `./dx up $1` from the dev-stack directory (find it with `ls dev-stack/dx` or
by searching upward for a directory containing `dx` and `stack.yml`).

If it fails, run `./dx preflight` and report which check failed - do not retry
`dx up`, because a second run starts a second image build.

When it succeeds, report the URLs from the output and nothing else. Do not
summarise the build log.

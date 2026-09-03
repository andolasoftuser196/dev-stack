---
description: Start the ssmd dev-stack and report where everything is
argument-hint: "[core|default|tools|full]"
allowed-tools: Bash(*/ssmd up*), Bash(*/ssmd status*), Bash(*/ssmd urls*), Bash(*/ssmd preflight*)
---

Start this project's development environment.

Run `./ssmd up $1` from the dev-stack directory (find it with `ls dev-stack/ssmd` or
by searching upward for a directory containing `ssmd` and `stack.yml`).

If it fails, run `./ssmd preflight` and report which check failed - do not retry
`ssmd up`, because a second run starts a second image build.

When it succeeds, report the URLs from the output and nothing else. Do not
summarise the build log.

# Agent sandboxes - what they buy, and what they do not

This document is written to be believed. Sandboxing claims that overstate what
they enforce are worse than no claims: people then run things unattended that
they would otherwise have watched.

## The shape

```
                     host
  ┌───────────────────────────────────────────────────────────┐
  │                                                           │
  │   default network (has a route out)                       │
  │   ┌──────────┬──────────┬──────────┬──────────┐           │
  │   │  proxy   │  mysql   │  redis   │  egress  │           │
  │   └────┬─────┴────┬─────┴────┬─────┴────┬─────┘           │
  │        │          │          │          │  ← the ONLY     │
  │  ══════╪══════════╪══════════╪══════════╪══  bridge       │
  │        │          │          │          │                 │
  │   no-egress network   (internal: true - no route out)     │
  │   ┌────┴─────┬──────────────┬───────────┴──────┐          │
  │   │ instance │   sandbox    │     browser      │          │
  │   │   app    │  (the agent) │  (headed chrome) │          │
  │   └──────────┴──────────────┴──────────────────┘          │
  └───────────────────────────────────────────────────────────┘

  sandbox mounts:  /app     this instance's git worktree          (rw)
                   /ssmd      the toolkit                          (ro, with one
                            rw window at /ssmd/data/state for audit)
                   /ssmd-ca   the stack's local CA                  (ro)
                   the human's checkout is NOT mounted
```

## What the isolation actually enforces

In descending order of how much each one buys.

### 1. Network - strong, and enforced by the kernel

The `no-egress` network is created with `internal: true`. Docker still allocates
a gateway *address* on such a network - `docker network inspect` will show one,
which misleads people into thinking it routes - but it installs no masquerade
rule and no route to the outside, and the embedded DNS resolver refuses external
names.

Measured, not assumed: from a container on this network, `getent hosts
example.com` returns nothing and `curl https://example.com/` fails at name
resolution before it ever opens a socket. This is not an allowlist someone has to
remember to update; it is the absence of a route.

The only way out is the `egress` container, which sits on both networks and runs
tinyproxy with `FilterDefaultDeny Yes` against `policy/allow-hosts.txt`. The
sandbox reaches it through `HTTP_PROXY`/`HTTPS_PROXY`, which curl, git-over-HTTPS,
composer, npm, pip, go and the Claude Code CLI all honour.

**What this does not cover:** anything that does not speak HTTP proxy - DNS
tunnelling, a raw socket, git over SSH. Those do not get out by another route;
they simply fail, because there is no route. That is the intended behaviour and
it is why the network boundary, not the proxy, is the control.

**Weakness worth knowing:** the proxy filters on the hostname in `CONNECT`. It
does not inspect TLS, so an allowed host that proxies elsewhere is a hole. Keep
`allow-hosts.txt` short. Every entry is a place a prompt-injected agent could send
your repository.

### 2. Filesystem - strong for the repository, ordinary otherwise

The instance's git worktree is mounted at `/app` and is the only writable path
into the repository. The human's checkout is not mounted at all, so an agent
cannot edit the branch they are on even by accident.

`/ssmd` is read-only, with one deliberate writable window at `/ssmd/data/state` so
the audit trail from inside the sandbox lands in the same file as the one
outside. The CA mounts at `/ssmd-ca`, not inside `/ssmd` - Docker has to *create* a
bind mount's mountpoint, and it cannot create one inside a read-only mount.

The `guard-path` hook additionally refuses writes outside `/app` and
`/home/agent` when `SSMD_SANDBOX=1`. That is defence in depth against a confused
agent, not against a determined one: it is a Claude Code hook, so it constrains
Claude Code's tools and nothing else. A shell command that writes elsewhere is
constrained by the container's mounts, which is the real control.

### 3. Resources - not security, but the difference between two very different bad days

`cpus`, `mem_limit`, `memswap_limit` and `pids_limit` from `stack.yml`.

- `memswap_limit` equal to `mem_limit` means **no swap**. Swapping turns a
  memory-hungry run into a twenty-minute one instead of failing in thirty
  seconds, and those twenty minutes are spent making every other container slow.
- Docker's memory cap is a hard SIGKILL, and the exec returns **exit code 137**
  with a truncated log. "The agent's fix broke the tests" and "the container ran
  out of memory" lead to completely different next actions, so learn to read 137.
- `pids_limit` protects the *other* services on the box: without it, anything in
  a container can fork until the host's pid table is exhausted.

Check the arithmetic before raising `max_concurrent`: `ssmd preflight` warns when
`max_concurrent × memory` plus the base stack exceeds the machine's RAM.

### 4. Privileges - defence in depth, nothing more

`no-new-privileges:true`, `cap_drop: ALL` plus `CHOWN`, `SETUID`, `SETGID`,
`DAC_OVERRIDE` (which the runtime images need to drop to the host UID). Not
privileged, no docker socket.

This protects against a compromised dependency escalating inside the container.
It does not protect against the agent, which is a normal user in its own worktree
and is supposed to be.

## What it explicitly does not protect against

**The agent can commit and push, if you give it credentials.** Nothing here stops
that. If `GITHUB_TOKEN` is in the environment, it is in the sandbox. The control
is the review gate and your branch protection, not the container.

**The agent can change anything in its worktree.** Including tests. A change that
edits the assertions to match new behaviour passes its own suite. The review gate
holds test-config and baseline files for exactly this reason - see
`policy/denied-paths.tsv`, and add your project's own.

**The orchestrator is host-root-equivalent.** `ssmd` runs on the host and manages
containers; the MCP server mounts the docker socket. That is irreducible - making
containers is the job - and it is why the MCP server is bound to loopback and
gated behind a profile rather than on by default.

**Prompt injection is not solved, only contained.** Everything the application
renders is injection input: ticket text, comments, uploads, output from a
previous agent. The sandbox means the blast radius of following such an
instruction ends at this network and this worktree. It does not mean the agent
will not follow one.

## Addressing the app: never by `app`

Compose gives every service a network alias equal to its **service name**, and
there is no way to suppress it. Every instance calls its app service `app`, so
plain `app` on the shared isolated network resolves round-robin across the base
stack and every running instance - a sandbox verifying "its" app would silently
hit someone else's a third of the time.

The unambiguous names are the instance slug (an explicit alias) and the container
name. `$SSMD_APP_URL` in the sandbox is set to the latter; the base stack's app has
the alias `main`.

```
http://$SSMD_APP_URL/     this instance          ✓
http://<slug>/          this instance          ✓
http://main/            the base stack's app   ✓
http://app/             whichever answers first ✗
```

## The review gate

`ssmd agent diff <slug>` evaluates the change against `policy/denied-paths.tsv` and
the size caps in `policy/policy.yml`, and returns a verdict.

**It never blocks the work.** This is the most important sentence in the design.
A change touching a migration is often exactly right; it just must not land
unattended. A gate that refused to produce the change would throw away correct
fixes for touching a file, and would be switched off within a month - taking the
rules that mattered with it.

Two independent checks:

- **Denied paths** - schema, routing, tenancy scoping, auth middleware, billing,
  lockfiles, CI workflows, test configuration and baselines. The files where a
  plausible-looking change is most dangerous. Each rule carries its reason,
  because a bare list of globs invites the next person to "just add one".
- **Size caps** - 5 files, 200 lines. Not a quality judgement. A proxy for "a
  human can review this in one sitting".

**Do not restructure a correct change to get under the caps.** Splitting a
coherent 300-line change into two 150-line ones makes it harder to review, not
easier. The verdict routes work to a reviewer; it is not a score to optimise.

The gate ships with unattended landing **off**. Turning it on is a deliberate act
by someone who has read `ssmd agent audit` for a while.

## Leases

Each sandbox holds a lease with an owner and an expiry. Without one, an agent
that crashed holds a slot and a Redis logical database forever, and both are hard
limits.

`ssmd agent reap` removes sandboxes whose lease has expired, after asking. It is an
explicit command rather than something `ssmd up` does, because several sandboxes
run at once and there is no moment when "anything that exists is debris" is true.
(A strictly serial runner *can* sweep at startup for exactly that reason: at
startup nothing legitimate exists, so anything matching is debris. Running
several at once removes that guarantee, and the lease is what replaces it.)

## Operating it

```bash
ssmd agent spawn <branch> --owner claude --ttl 4h --egress allowlist
ssmd agent ls                       # slugs, branches, leases, URLs
ssmd agent attach <slug>            # a shell inside
ssmd agent run <slug> '<command>'   # one command inside
ssmd agent verify <slug>            # does the app still work?
ssmd agent diff <slug>              # what changed, and the verdict
ssmd agent audit -n 100             # what has actually been done
ssmd agent rm <slug> --drop-db      # snapshots, then drops
ssmd agent reap
```

`--egress full` exists for development convenience. It gives the sandbox normal
networking, which means the isolation is one boundary short. Do not use it for
anything unattended.

## If an agent goes off the rails

Stop the run. Snapshot the page and the transcript. Look at **the most recent
application input the agent saw** - a ticket description, a comment, an uploaded
file, the output of a tool.

Treat it as a prompt-injection incident, not a model quirk, until proven
otherwise. `ssmd agent audit` and `data/state/agent-tools.jsonl` record what was
attempted and what was refused, which is where the reconstruction starts.

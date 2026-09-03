# Parallel instances

`ssmd wt` runs several branches at once, each a full environment at
`https://<slug>.<domain>/`.

```bash
ssmd wt add feature/billing
ssmd wt ls
ssmd wt logs billing -f
ssmd wt verify billing
ssmd wt rm billing --drop-db
```

## What an instance gets

| Resource | Isolated how |
|---|---|
| Code | its own git worktree under `repo.worktree_root` |
| Database | its own database `<db>_<slug>` on the shared server |
| Cache | its own Redis logical database (1–15) and key prefix |
| Storage | its own bucket named after the slug |
| Routing | `<slug>.<domain>`, written into `caddy/proxy/sites/<slug>.caddy` |
| Mail | shared - one inbox for everything is what you want here |

**Shared: the database server, Redis, Mailpit, MinIO and the proxy.** That
sharing is the whole trick. Per-branch stacks that each run their own MySQL are
what everyone builds first, and they stop being usable at three concurrent
branches because the memory is gone.

## The ceiling is Redis, not memory

Redis has sixteen logical databases and the base stack owns 0. **Fifteen
concurrent instances is a hard limit**, and it will bite before RAM does on any
reasonable machine. `ssmd wt ls` shows what is allocated; `ssmd wt rm` frees it.

In practice the useful number is lower - each instance runs an app container and
optionally a worker, so six to eight is comfortable on 16 GB.

## Provisioning: snapshots, not migrations

A new instance seeds its database from the most recent snapshot by default.
Restoring a 200 MB dump takes about twenty seconds; building the same schema from
migrations can take minutes, and a two-minute wait is enough to stop people
creating instances at all.

```bash
ssmd db:snapshot                              # keep a good one around
ssmd wt add feature/x                         # seeds from the newest
ssmd wt add feature/x --from-snapshot <file>  # pick one
ssmd wt add feature/x --empty-db              # skip it - for testing the migration chain
```

`--empty-db` is the right choice when the thing under test *is* the migration
chain from empty. It is the wrong choice the rest of the time.

## DNS

With wildcard DNS (`*.<domain>` → this machine) instances just work. Without it,
`/etc/hosts` cannot express a wildcard, so each instance needs a line - `ssmd`
prints it, and writes it for you only if `MANAGE_ETC_HOSTS=1` and you have
passwordless sudo.

Setting up a wildcard once (dnsmasq, or your router's resolver) is worth more
than it sounds: it is the difference between `ssmd wt add` being one command and
being one command plus a sudo prompt.

## Removing one

```bash
ssmd wt rm <slug>                    # keeps the branch and the database
ssmd wt rm <slug> --drop-db          # snapshots the database first, then drops it
ssmd wt rm <slug> --delete-branch    # also deletes the branch, if it is merged
```

`--delete-branch` uses `git branch -d`, never `-D`. A branch with unmerged
commits is exactly the branch you do not want deleted by a cleanup command, and
git already knows how to tell the difference - ssmd reports it and leaves the
branch in place.

Removing an instance deletes its git worktree. Check for uncommitted work first:
`git -C <path> status`. ssmd does not check for you, because a prompt in a teardown
command is a prompt people learn to answer without reading.

## Drift

Containers removed by hand, worktrees deleted with `rm`, branches gone from the
remote, routes left behind by an interrupted teardown - `ssmd doctor` finds all of
it and fixes none of it, on purpose. It reports what is wrong and names the
command; an auto-fixing doctor is one you stop trusting, because you can no
longer tell what it changed while you were reading its output.

## Instances and agents are the same thing

`ssmd agent spawn` creates an instance through exactly the same code path, then
adds a sandbox container, a lease and an egress policy. Keeping them one
implementation is what stops the two from drifting apart - a fix to instance
networking cannot land for worktrees and miss agents.

See [AGENTS.md](AGENTS.md).

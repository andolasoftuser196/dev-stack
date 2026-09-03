---
description: Find drift between what dx believes and what is actually running
allowed-tools: Bash(*/dx doctor*), Bash(*/dx status*), Bash(*/dx wt ls*)
---

Run `./dx doctor`.

It is read-only and never fixes anything, so report what it found and propose the
specific fix for each item rather than acting immediately. Common ones:

| Finding | Fix |
|---|---|
| instance registered but no container | `dx wt up <slug>` |
| worktree gone | `dx wt rm <slug>` - the registry is stale |
| orphan proxy route | a teardown did not finish; `dx wt rm <slug>` |
| expired lease | `dx agent reap` |
| database missing for an instance | `dx wt rm <slug>` then re-add |

Ask before running anything destructive.

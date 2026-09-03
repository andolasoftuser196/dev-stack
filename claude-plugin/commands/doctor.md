---
description: Find drift between what ssmd believes and what is actually running
allowed-tools: Bash(*/ssmd doctor*), Bash(*/ssmd status*), Bash(*/ssmd wt ls*)
---

Run `./ssmd doctor`.

It is read-only and never fixes anything, so report what it found and propose the
specific fix for each item rather than acting immediately. Common ones:

| Finding | Fix |
|---|---|
| instance registered but no container | `ssmd wt up <slug>` |
| worktree gone | `ssmd wt rm <slug>` - the registry is stale |
| orphan proxy route | a teardown did not finish; `ssmd wt rm <slug>` |
| expired lease | `ssmd agent reap` |
| database missing for an instance | `ssmd wt rm <slug>` then re-add |

Ask before running anything destructive.

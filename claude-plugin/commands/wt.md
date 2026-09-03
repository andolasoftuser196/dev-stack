---
description: Manage parallel branch environments (git worktree instances)
argument-hint: "add <branch> | ls | rm <slug> | logs <slug>"
allowed-tools: Bash(*/dx wt*), Bash(*/dx verify*)
---

Run `./dx wt $ARGUMENTS`.

Each instance is a full environment at `https://<slug>.<domain>/` with its own
checkout, database, Redis logical database and storage bucket, sharing the base
stack's backing services.

Notes worth acting on:

- New instances are seeded from the most recent snapshot. Pass `--empty-db` when
  you are specifically testing the migration chain from empty.
- Redis has fifteen usable logical databases, so fifteen concurrent instances is
  a hard ceiling. `dx wt ls` shows what is allocated.
- `dx wt rm` deletes a git worktree. Check for uncommitted work first
  (`git -C <path> status`) and say what you found before removing it.

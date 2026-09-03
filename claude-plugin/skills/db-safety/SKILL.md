---
name: db-safety
description: Rules for touching a dx stack's database - running migrations, loading data, resetting state, and running tests that truncate tables. Use before any operation that writes to, resets, or drops a database.
---

# Database safety in a dx stack

One rule underneath all of the specifics: **anything that can lose data takes a
snapshot first, and if the snapshot fails, the operation does not run.** dx
enforces this. Do not work around it.

## Never run the test suite outside `dx test`

A suite using a "refresh the database" trait reads whatever database the
configuration names and drops every table in it. If that configuration points at
the development database - and it does, more often than anyone expects, because
the test config's own override is frequently commented out - the suite destroys
the data you were working with.

```bash
./dx test                       # correct: targets <db>_test, creates it if needed
./dx test --filter=UserTest     # filters pass through
```

`dx test` refuses to run if the database name it computed does not match a
disposable pattern (`*_test`, `*_sandbox`). The policy hooks additionally block
`php artisan test`, `phpunit`, `pytest` and `go test` invoked directly, and the
denial message names `dx test` as the alternative.

## Snapshots are the provisioning mechanism, not just the backup

```bash
./dx db:snapshot              # before anything you are unsure about
./dx db:snapshots             # list them
./dx db:restore <file>        # snapshots the current state first, always
```

New worktree and agent instances are seeded from the most recent snapshot by
default. A restore of a 200MB dump takes about twenty seconds; building the same
schema from migrations can take minutes. Taking a good snapshot makes every
future instance start fast, which is what decides whether people use instances at
all.

## Dropping a database

```bash
./dx db:drop <name>
```

dx refuses unless the name matches a disposable pattern, and it snapshots first.
It will not drop the development database at all - `dx nuke` is the deliberate
path for that, and it says exactly what it is about to destroy.

`DROP DATABASE` and `TRUNCATE TABLE` typed into a shell are blocked by policy.
That is not paranoia about you; it is that an ambiguous instruction should not be
able to become a dropped database.

## Migrations

```bash
./dx db:migrate
```

Runs the project's migration command for its framework. Two things to know:

- **Migrations are on the review-gate list.** A change under `migrations/` is
  held for a human by `dx agent diff`. The change is not wrong - schema changes
  need eyes, and a plausible-looking migration is among the most dangerous
  things an agent can write.
- **A fresh database and a migrated one can differ.** Projects that ship a schema
  dump alongside their migrations take a different code path for `migrate` and
  `migrate:fresh`. If a fresh checkout behaves differently from yours, this is
  usually why.

## Loading real data

Do not load production data into a dev stack. If reproducing a customer-reported
bug genuinely needs real data, anonymise it first - and remember that
`data/snapshots/` is gitignored precisely because a dump taken "just for today"
is exactly the thing that turns out to contain a real customer record six months
later.

## Per-instance databases

Every worktree and agent instance gets its own database (`<db>_<slug>`), its own
Redis logical database and its own storage bucket. They share one database
*server*, not one database. That is what makes several branches affordable at
once, and it means a migration that goes wrong on one branch cannot be seen from
another.

Redis has sixteen logical databases and the base stack owns 0, so fifteen
concurrent instances is a hard ceiling. `dx wt ls` shows which are allocated.

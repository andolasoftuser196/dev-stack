---
description: Spawn and manage isolated agent sandboxes
argument-hint: "spawn <branch> | ls | attach <slug> | diff <slug> | rm <slug>"
allowed-tools: Bash(*/ssmd agent*), Bash(*/ssmd verify*)
---

Run `./ssmd agent $ARGUMENTS`.

If the subcommand is `diff`, read the verdict carefully and relay it accurately:

- **"within policy"** means small and nothing load-bearing was touched. It still
  needs a review unless unattended landing has been explicitly enabled, which it
  is not by default.
- **"held"** does **not** mean the change is wrong. It means a human should look,
  because the change touches something where a plausible-looking edit is
  dangerous (migrations, lockfiles, middleware, tenancy scoping, CI config) or is
  larger than one sitting of review.

Never suggest restructuring a correct change to get under the size caps. That
makes it harder to review, not easier, and defeats the purpose of the gate.

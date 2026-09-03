#!/usr/bin/env bash
# A script that is executed rather than sourced must carry the executable bit,
# and the bit that matters is the one recorded in git - not the one on the
# machine that wrote the file. Every developer's checkout inherits the mode from
# the index, so a file that works locally because the author's umask was kind
# fails on every clone.
#
# Both bugs this catches shipped: `ssmd init` died with "Permission denied"
# before it printed anything, and the browser service could not start at all
# because compose runs the bind-mounted entrypoint as its command. Neither is
# visible to any other test - the first is the one command that runs before a
# stack exists, and no test starts the browser profile.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"

t_section "files ssmd execs directly"

# Anything reached by `exec` from the entry point, plus the compose command:
# entries that run a bind-mounted script.
EXECUTED="scaffold/init.sh
          tests/run
          lib/completion.sh
          agent/sandbox/browser-entrypoint.sh
          agent/egress/entrypoint.sh
          runtimes/frankenphp/entrypoint.sh
          runtimes/node/entrypoint.sh
          runtimes/python/entrypoint.sh
          runtimes/go/entrypoint.sh"

for f in $EXECUTED; do
    assert_ok "$f is executable on disk" test -x "$f"
    mode="$(git ls-files -s "$f" | awk '{print $1}')"
    assert_eq "100755" "$mode" "$f is 100755 in the index"
done

t_section "files that are sourced must not need the bit"

# Stated as the inverse so that making a library executable - which invites
# someone to run it, and a sourced file run directly does nothing useful or
# something surprising - shows up as a failure too.
SOURCED="lib/core.sh
         lib/config.sh
         lib/db.sh
         lib/instance.sh
         lib/worktree.sh
         lib/agent.sh
         lib/policy.sh
         lib/doctor.sh
         lib/sqlite.sh
         runtimes/frankenphp/commands.sh
         runtimes/node/commands.sh
         runtimes/python/commands.sh
         runtimes/go/commands.sh"

for f in $SOURCED; do
    mode="$(git ls-files -s "$f" | awk '{print $1}')"
    assert_eq "100644" "$mode" "$f is 100644 in the index"
done

t_section "every compose command: that names a script"

# Catches the next service added the same way the browser service was.
while read -r script; do
    [ -n "$script" ] || continue
    local_path="${script#/ssmd/}"
    match="$(git ls-files | grep -E "/${local_path}$" | head -1)"
    [ -n "$match" ] || continue
    assert_ok "compose runs $match, which is executable" test -x "$match"
done < <(grep -ohE 'command: \[ "[^"]+\.sh" \]' docker-compose*.yml \
         | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)

t_summary

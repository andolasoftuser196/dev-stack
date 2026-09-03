#!/usr/bin/env bash
# preflight is the command people run when nothing else worked, so it has to
# survive being run on a broken machine - which is exactly the machine where a
# stray shell error is hardest to tell apart from the problem being diagnosed.
#
# `$STACK_CACHE` shipped here, referenced once and assigned nowhere. Under
# `set -u` it printed
#
#     lib/doctor.sh: line 44: STACK_CACHE: unbound variable
#
# into the middle of the report, and the check it belonged to silently reported
# nothing. Every other command was fine, and doctor has an integration test;
# preflight had none, which is the whole reason this survived.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "no shell errors leak into the report"

# preflight exits non-zero on a machine that cannot run the stack, which is a
# normal outcome and not what is under test here - the output is.
out="$(cd "$SB" && ./ssmd preflight 2>&1)"

assert_not_contains "$out" "unbound variable" "no unbound variable escapes"
assert_not_contains "$out" "command not found" "no missing command escapes"
assert_not_contains "$out" "doctor.sh: line"   "no raw bash error names a line of doctor.sh"
assert_match "$out" 'stack\.yml compiles \([0-9]+ settings\)' \
    "the settings count is a number, not an empty substitution"

t_section "every STACK_ variable the code reads is one the config layer sets"

# The general form of the same bug. A name that is never assigned is either a
# typo or a key missing from defaults.yml, and both fail only on the line that
# reads it - which may be a branch nobody takes for months.
refs="$(grep -rhoE '\$\{?STACK_[A-Z_]+' "$SB/ssmd" "$SB"/lib/*.sh "$SB"/runtimes/*/commands.sh \
        | tr -d '${' | sort -u)"
missing=""
for v in $refs; do
    # Set in the resolved environment, or assigned somewhere in the code.
    [ -n "$(eval "printf '%s' \"\${$v+set}\"")" ] && continue
    grep -qE "(^|[^A-Z_])${v}=" "$SB/ssmd" "$SB"/lib/*.sh 2>/dev/null && continue
    missing="$missing $v"
done
assert_eq "" "$missing" "no STACK_ variable is read without ever being set"

t_summary

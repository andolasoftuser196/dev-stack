#!/usr/bin/env bash
# lib/instance.sh - registry, redis allocation, slugs, leases, routes.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "slugs"
assert_eq "feature-billing" "$(instance_slug_for_branch feature/billing)" "a branch becomes a slug"
assert_eq "fix-123-odd-name" "$(instance_slug_for_branch 'fix/123 odd_name')" "spaces and underscores collapse"
assert_eq "abc" "$(instance_slug_for_branch -abc-)" "leading and trailing separators trimmed"
for r in app main proxy db mail vnc mcp egress; do
    assert_fail "reserved slug '$r' is refused" instance_slug_for_branch "$r"
done
assert_fail "a branch that reduces to nothing is refused" instance_slug_for_branch "///"

t_section "registry"
assert_eq "0" "$(instances_count)" "starts empty"
instance_register alpha wt feature/a /tmp/a app_dev_a 1 tester
assert_eq "1" "$(instances_count)" "register adds one"
instance_exists alpha && t_ok "exists finds it" || t_fail "exists finds it"
instance_exists nope && t_fail "exists rejects an unknown slug" || t_ok "exists rejects an unknown slug"

instance_load alpha
assert_eq "alpha" "$INSTANCE_SLUG" "load: slug"
assert_eq "wt" "$INSTANCE_KIND" "load: kind"
assert_eq "feature/a" "$INSTANCE_BRANCH" "load: branch"
assert_eq "/tmp/a" "$INSTANCE_DIR" "load: worktree"
assert_eq "app_dev_a" "$INSTANCE_DB" "load: database"
assert_eq "1" "$INSTANCE_REDIS_DB" "load: redis db"
assert_eq "tester" "$INSTANCE_OWNER" "load: owner"
assert_fail "loading an unknown slug fails" instance_load nope

t_section "a row with empty columns still loads correctly"
# The field-separator bug would have shifted every field after an empty one.
instance_register beta agent "" /tmp/b "" 2 ""
instance_load beta
assert_eq "beta" "$INSTANCE_SLUG" "slug survives an empty branch"
assert_eq "/tmp/b" "$INSTANCE_DIR" "worktree did not shift into the branch column"
assert_eq "2" "$INSTANCE_REDIS_DB" "redis db did not shift"

t_section "redis allocation"
assert_eq "3" "$(instance_alloc_redis_db)" "lowest free number"
lo="$(config_get instances.redis_db_min)"; hi="$(config_get instances.redis_db_max)"
for n in $(seq 3 "$hi"); do instance_register "s$n" wt b /tmp/x db "$n" o; done
assert_fail "exhausting the pool fails rather than colliding" instance_alloc_redis_db
assert_contains "$(instance_alloc_redis_db 2>&1)" "concurrency ceiling" "and says what the ceiling is"
for n in $(seq 3 "$hi"); do instance_unregister "s$n"; done
assert_eq "3" "$(instance_alloc_redis_db)" "freeing one makes it available again"

t_section "the schema enforces uniqueness, not just the query"
assert_fail "a duplicate slug is refused" instance_register alpha wt b /tmp/z db 9 o
assert_fail "a duplicate redis db is refused" instance_register gamma wt b /tmp/z db 1 o

t_section "database naming"
assert_eq "app_dev_my_branch" "$(instance_db_name my-branch)" "hyphens become underscores"

t_section "leases"
lease_write alpha claude 2h
assert_eq "claude" "$(lease_owner alpha)" "owner recorded"
assert_match "$(lease_remaining alpha)" '^1[12][0-9]m$' "roughly two hours remain"
lease_expired alpha && t_fail "a fresh lease is not expired" || t_ok "a fresh lease is not expired"
# Backdated rather than slept-for: a one-second sleep races the integer-second
# epoch and made this flaky.
lease_write beta claude 1h
printf 'UPDATE leases SET expires = strftime("%%s","now") - 60 WHERE slug="beta";' | sq >/dev/null
lease_expired beta && t_ok "an elapsed lease is expired" || t_fail "an elapsed lease is expired"
assert_eq "expired" "$(lease_remaining beta)" "and says so"
lease_remove beta
assert_eq "-" "$(lease_owner beta)" "a removed lease has no owner"
lease_expired beta && t_ok "a missing lease counts as expired" || t_fail "a missing lease counts as expired"
for u in 30m 2h 1d; do lease_write alpha o "$u"; done
t_ok "m, h and d suffixes are all accepted"

t_section "removing an instance cascades its lease"
lease_write alpha claude 4h
instance_unregister alpha
assert_eq "0" "$(printf 'SELECT COUNT(*) FROM leases WHERE slug="alpha";' | sq1)" \
    "the lease went with the instance"

t_section "routes"
instance_register delta wt b /tmp/d db 5 o
INSTANCE_KIND=wt instance_write_route delta "app-dev-wt-delta-app:80"
assert_file "caddy/proxy/sites/delta.caddy" "a route file is written"
assert_contains "$(cat caddy/proxy/sites/delta.caddy)" "delta.app.test" "with the instance hostname"
assert_contains "$(cat caddy/proxy/sites/delta.caddy)" "flush_interval -1" "and unbuffered responses"
instance_remove_route delta
assert_no_file "caddy/proxy/sites/delta.caddy" "and removed again"
assert_file "caddy/proxy/sites/00-placeholder.caddy" "the placeholder is never removed"

t_section "listing"
out="$(instances_list)"
assert_contains "$out" "delta" "lists an instance"
assert_contains "$out" "SLUG" "with a header"
assert_not_contains "$(instances_list agent)" "delta" "filters by kind"
instance_unregister delta; instance_unregister beta
assert_contains "$(instances_list)" "no instances" "says so when empty"

t_summary

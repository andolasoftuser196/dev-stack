#!/usr/bin/env bash
# lib/config.sh + lib/sqlite.sh - the config store, layering and cache.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"

SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "seeding"
assert_ok "the database exists after first load" test -f "$DX_DB_PATH"
assert_ne "0" "$(printf 'SELECT COUNT(*) FROM config;' | sq1)" "config rows were seeded"
for s in default stack host:local; do
    n="$(printf 'SELECT COUNT(*) FROM config WHERE scope=%s;' "$(sq_quote "$s")" | sq1)"
    assert_ne "0" "$n" "scope '$s' populated"
done
assert_eq "6" "$(printf "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%%';" | sq1)" \
    "all six tables created"

t_section "layer resolution"
assert_eq "127.0.0.1" "$(config_get proxy.bind)" "host:local wins for proxy.bind"
assert_eq "caddy:2-alpine" "$(config_get images.proxy)" "default layer provides images.proxy"
assert_eq "app" "$(config_get name)" "stack layer provides name"

# stack must beat default
config_set images.proxy caddy:test stack >/dev/null
assert_eq "caddy:test" "$(config_get images.proxy)" "stack overrides default"
# host must beat stack
config_set images.proxy caddy:host "host:local" >/dev/null
assert_eq "caddy:host" "$(config_get images.proxy)" "host overrides stack"
config_unset images.proxy "host:local" >/dev/null
assert_eq "caddy:test" "$(config_get images.proxy)" "removing the host layer falls back to stack"
config_unset images.proxy stack >/dev/null
assert_eq "caddy:2-alpine" "$(config_get images.proxy)" "removing the stack layer falls back to default"

t_section "a different host profile resolves differently"
( load_sandbox "$SB" vm >/dev/null 2>&1
  [ "$(config_get proxy.bind)" = "0.0.0.0" ] ) \
  && t_ok "DX_HOST=vm gives 0.0.0.0" || t_fail "DX_HOST=vm gives 0.0.0.0"
( load_sandbox "$SB" alt-ports >/dev/null 2>&1
  [ "$(config_get proxy.https)" = "8443" ] ) \
  && t_ok "DX_HOST=alt-ports gives 8443" || t_fail "DX_HOST=alt-ports gives 8443"
load_sandbox "$SB" local

t_section "history"
# The default layer seeded 5000; setting it in `stack` is a *new* row in that
# scope, not a change to the default's. History is per scope, which is the
# honest model - the effective value changed, but nothing in `default` did.
config_set tuning.mail_max_messages 99 stack >/dev/null
h="$(config_history tuning.mail_max_messages)"
assert_contains "$h" "set 99" "setting a key a scope did not have is recorded as a set"
assert_contains "$h" "test" "the actor is recorded"
config_set tuning.mail_max_messages 88 stack >/dev/null
assert_contains "$(config_history tuning.mail_max_messages)" "99 -> 88" \
    "changing it again records both sides"
config_unset tuning.mail_max_messages stack >/dev/null
assert_contains "$(config_history tuning.mail_max_messages)" "removed" "an unset is recorded too"

t_section "unset of an absent key is an error, not a silent no-op"
assert_fail "unsetting a key the scope does not have fails" config_unset no.such.key stack

t_section "cache"
# config_set removes the cache so the next dx rebuilds it; reload to get one.
load_sandbox "$SB" local
assert_file "$SB/.stack.env" "the cache file exists"
assert_contains "$(cat "$SB/.stack.env")" "# host=local" "the cache records which host it was built for"
before="$(stat -c %Y "$SB/.stack.env")"
config_set name app stack >/dev/null      # same value, but a write bumps the db
config_cache_stale && t_ok "a config write invalidates the cache" \
                   || t_fail "a config write invalidates the cache"
# a newer seed must also invalidate
config_build_cache; touch "$SB/config/stack.yml"
config_cache_stale && t_ok "a newer seed invalidates the cache" \
                   || t_fail "a newer seed invalidates the cache"

t_section "editing a seed re-imports automatically"
printf '\ntest_marker: hello\n' >> "$SB/config/stack.yml"
load_sandbox "$SB" local
assert_eq "hello" "$(config_get test_marker)" "a key added to a seed appears without an explicit import"
# and removing it removes the row, rather than leaving it forever
python3 - "$SB/config/stack.yml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("\ntest_marker: hello\n", "\n"))
PY
load_sandbox "$SB" local
assert_fail "a key removed from a seed is removed from the database" config_get test_marker

t_section "quoting"
config_set weird.value "a'b\"c d" stack >/dev/null
assert_eq "a'b\"c d" "$(config_get weird.value)" "quotes and spaces survive a round trip"
load_sandbox "$SB" local
assert_eq "a'b\"c d" "$STACK_WEIRD_VALUE" "and survive the cache too"
config_unset weird.value stack >/dev/null

t_section "sqlite backends agree"
if command -v sqlite3 >/dev/null 2>&1 && python3 -c 'import sqlite3' 2>/dev/null; then
    q='SELECT key,value FROM config WHERE scope="default" ORDER BY key;'
    a="$(printf '%s' "$q" | sqlite3 -batch -noheader -separator "$DX_FS" "$DX_DB_PATH" | md5sum)"
    b="$(printf '%s' "$q" | python3 "$SB/lib/dxdb.py" "$DX_DB_PATH" | md5sum)"
    assert_eq "$a" "$b" "the cli and python backends return identical bytes"
else
    t_skip "backend comparison" "need both sqlite3 and python3"
fi

t_section "empty columns survive the field separator"
# The bug this guards: tab is IFS whitespace, so `read` collapsed runs of it and
# an empty column shifted every field after it.
printf "SELECT 'a','','c';" | sq | { IFS="$DX_FS" read -r x y z
    assert_eq "a" "$x" "field 1"
    assert_eq ""  "$y" "field 2 is empty and still present"
    assert_eq "c" "$z" "field 3 did not shift left"; }

t_summary

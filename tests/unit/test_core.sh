#!/usr/bin/env bash
# lib/core.sh - derivation. The rule under test throughout: every value comes
# from config, and nothing is invented in code.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "identity and paths"
assert_eq "app-dev" "$PROJECT" "project name derives from the stack name"
assert_eq "app-dev/frankenphp:8.3" "$APP_IMAGE" "app image derives from name, runtime and version"
assert_eq "dunglas/frankenphp:1-php8.3" "$RUNTIME_BASE_IMAGE" "{version} substituted into the base image template"
assert_ok "repo.root resolved to a real directory" test -d "$APP_DIR"

t_section "ports are derived, stable and distinct"
first="$PORT_OFFSET"
( load_sandbox "$SB" local >/dev/null 2>&1; [ "$PORT_OFFSET" = "$first" ] ) \
    && t_ok "the offset is stable across invocations" || t_fail "the offset is stable across invocations"
lo="$(config_get port_offset.span_min)"; span="$(config_get port_offset.span)"
[ "$PORT_OFFSET" -ge "$lo" ] && [ "$PORT_OFFSET" -lt $((lo+span)) ] \
    && t_ok "the offset is inside the configured span" \
    || t_fail "the offset is inside the configured span" "got $PORT_OFFSET, want ${lo}..$((lo+span-1))"
assert_eq "$(( $(config_get port_offset.base_db) + PORT_OFFSET ))" "$DB_PORT" "db port = base + offset"
assert_eq "$(( $(config_get port_offset.base_cache) + PORT_OFFSET ))" "$CACHE_PORT" "cache port = base + offset"
u="$(printf '%s\n' "$DB_PORT" "$CACHE_PORT" "$S3_PORT" "$VNC_PORT" "$MCP_PORT" | sort -u | wc -l)"
assert_eq "5" "$u" "the five derived host ports are distinct"

# A different stack name must land elsewhere, or two stacks collide.
config_set name other stack >/dev/null; load_sandbox "$SB" local
assert_ne "$first" "$PORT_OFFSET" "a different stack name gives a different offset"
config_set name app stack >/dev/null; load_sandbox "$SB" local

t_section "engine selection"
assert_eq "mysql" "$DB_ENGINE" "engine from config"
assert_eq "$(config_get ports.mysql)" "$DB_INTERNAL_PORT" "mysql internal port from config"
assert_eq "mysql:8.0" "$DB_IMAGE" "db image combines the default image with the project's version"
config_set services.database postgres stack >/dev/null
config_set database.version 16 stack >/dev/null
load_sandbox "$SB" local
assert_eq "postgres" "$DB_ENGINE" "switching the engine takes effect"
assert_eq "$(config_get ports.postgres)" "$DB_INTERNAL_PORT" "postgres internal port follows"
assert_eq "postgres:16" "$DB_IMAGE" "postgres image follows"
config_set services.database none stack >/dev/null; load_sandbox "$SB" local
assert_eq "" "$DB_IMAGE" "database: none produces no image"
# NOT zero. The mysql/postgres service definitions still have to parse -
# `docker compose config` validates the whole file, not just the profiles being
# started, and it rejects a target port of 0. The port stays a real number that
# nothing connects to; db_require() is the guard that actually stops use.
assert_ne "0" "$DB_INTERNAL_PORT" "database: none keeps a parseable port for compose"
assert_fail "and db_require refuses regardless" db_require
config_set services.database mysql stack >/dev/null
config_set database.version 8.0 stack >/dev/null; load_sandbox "$SB" local

t_section "per-runtime inner port"
for pair in "frankenphp 0" "node 3000" "python 8000" "go 8080"; do
    set -- $pair
    config_set runtime.kind "$1" stack >/dev/null; load_sandbox "$SB" local
    assert_eq "$2" "$SSMD_APP_PORT" "runtime '$1' -> inner port $2"
done
config_set runtime.kind frankenphp stack >/dev/null; load_sandbox "$SB" local

t_section "an unknown runtime fails loudly"
config_set runtime.kind nonesuch stack >/dev/null
out="$(cd "$SB" && ./ssmd describe 2>&1)"; rc=$?
assert_ne "0" "$rc" "ssmd refuses an unknown runtime"
assert_contains "$out" "Available:" "and lists what it does support"
config_set runtime.kind frankenphp stack >/dev/null

t_section "profiles come from config, not from code"
assert_eq "" "$(profiles_for_preset core)" "core enables nothing extra"
assert_eq "queue scheduler" "$(profiles_for_preset default)" "default preset"
assert_fail "an unknown preset is rejected" profiles_for_preset nonesuch
assert_contains "$(preset_names | tr '\n' ' ')" "full" "preset names are discovered, not listed"
# adding one must need no code change
config_set presets.minimal "queue" stack >/dev/null; load_sandbox "$SB" local
assert_eq "queue" "$(profiles_for_preset minimal)" "a preset added in config works immediately"
config_unset presets.minimal stack >/dev/null

assert_contains " $(all_profiles) " " sandbox " "profiles.all covers the sandbox profile"
for p in mysql postgres redis mailpit minio queue scheduler tools browser mcp egress; do
    case " $(all_profiles) " in *" $p "*) ;; *) t_fail "profiles.all covers '$p'" ;; esac
done
t_ok "profiles.all covers every profile used by the compose files"

t_section "service selection drives profiles"
load_sandbox "$SB" local
assert_contains " $(profiles_for_services) " " mysql " "the chosen engine is in the profile set"
assert_not_contains " $(profiles_for_services) " " postgres " "the unchosen engine is not"

t_section "_cfg fails loudly on a missing key rather than yielding empty"
assert_fail "_cfg dies on an unknown key" _cfg NO_SUCH_KEY_AT_ALL
assert_eq "fallback" "$(_cfgd NO_SUCH_KEY_AT_ALL fallback)" "_cfgd tolerates absence"

t_section "container naming"
assert_eq "app-dev-app" "$(container app)" "container names are project-prefixed"

t_summary

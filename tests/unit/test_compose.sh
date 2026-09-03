#!/usr/bin/env bash
# The compose files must resolve for every combination the toolkit allows, and
# must contain no literals. `docker compose config` parses locally - no daemon,
# no containers, no network.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"

if ! have_docker; then
    t_skip "compose validation" "docker CLI not installed"; t_summary; exit
fi

SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

# Export everything dx derives, exactly as dx does before invoking compose.
dxenv() {
    load_sandbox "$SB" "${1:-local}" >/dev/null 2>&1
    export INSTANCE_SLUG=probe INSTANCE_KIND=agent INSTANCE_DIR=/tmp \
           INSTANCE_DB=probe_db INSTANCE_REDIS_DB=1 AGENT_OWNER=t AGENT_PROXY=
}

t_section "no literals left in the compose files"
# Comment lines carry the reasoning and legitimately mention these numbers; only
# actual settings are under test. (These greps are line-numbered across several
# files, so they strip comments from the grep OUTPUT rather than using
# code_only, which takes a single filename.)
nocomments() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; }

# The value after `image:` must begin with a quote or a $. Note the explicit
# [[:space:]]+ - a greedy \s* backtracks onto the separating space and makes
# [^"$] match it, which is how the first version of this check passed nothing.
lit="$(grep -nE '^[[:space:]]*image:[[:space:]]+[^"$[:space:]]' \
        docker-compose.yml docker-compose.instance.yml | nocomments || true)"
assert_eq "" "$lit" "every image: is an interpolation"

lit="$(grep -nE ':(3306|5432|6379|8025|1025|9000|9001|8081|7900|8888)\b' \
        docker-compose.yml docker-compose.instance.yml | nocomments | grep -v '\${' || true)"
assert_eq "" "$lit" "no port literals"

lit="$(grep -nE '(256M|256mb|max-connections=[0-9]|shm_size:[[:space:]]*[0-9]|1600x1000)' \
        docker-compose.yml docker-compose.instance.yml | nocomments | grep -v '\${' || true)"
assert_eq "" "$lit" "no tuning literals"

t_section "base stack resolves for every runtime x database"
for kind in frankenphp node python go; do
  for db in mysql postgres none; do
    config_set runtime.kind "$kind" stack >/dev/null
    config_set services.database "$db" stack >/dev/null
    case "$db" in mysql) config_set database.version 8.0 stack >/dev/null ;;
                  postgres) config_set database.version 16 stack >/dev/null ;; esac
    dxenv
    pargs=(); [ "$db" != none ] && pargs=(--profile "$db")
    assert_ok "$kind + $db" docker compose -f docker-compose.yml \
        "${pargs[@]}" --profile redis --profile mailpit --profile queue config -q
  done
done

t_section "every optional service resolves"
config_set runtime.kind frankenphp stack >/dev/null
config_set services.database mysql stack >/dev/null
config_set database.version 8.0 stack >/dev/null
dxenv
for p in mysql redis mailpit minio meilisearch pgvector queue scheduler tools browser mcp egress; do
    assert_ok "profile '$p'" docker compose -f docker-compose.yml --profile "$p" config -q
done
assert_ok "every profile at once" docker compose -f docker-compose.yml \
    $(for p in $(all_profiles); do printf -- '--profile %s ' "$p"; done) config -q

t_section "instance overlay resolves"
dxenv
assert_ok "worktree instance" docker compose -f docker-compose.instance.yml --profile queue config -q
assert_ok "agent instance with sandbox" docker compose -f docker-compose.instance.yml \
    --profile queue --profile sandbox config -q

t_section "the sandbox is hardened as configured"
dxenv
cfg="$(docker compose -f docker-compose.instance.yml --profile sandbox config 2>/dev/null)"
assert_contains "$cfg" "no-new-privileges:true" "no-new-privileges set"
assert_match "$cfg" 'cap_drop:[[:space:]]*(- )?ALL|- ALL' "capabilities dropped"
assert_contains "$cfg" "pids_limit: $(config_get agents.pids_limit)" "pids_limit from config"
assert_contains "$cfg" "read_only: true" "the toolkit is mounted read-only"
# The memory cap and swap cap must be equal, or a hungry run swaps for 20
# minutes instead of failing in 30 seconds.
m="$(printf '%s' "$cfg" | grep -oE 'mem_limit: [0-9]+' | head -1 | awk '{print $2}')"
sw="$(printf '%s' "$cfg" | grep -oE 'memswap_limit: [0-9]+' | head -1 | awk '{print $2}')"
assert_eq "$m" "$sw" "memswap_limit equals mem_limit - no swap"

t_section "no service is reachable only by the ambiguous name 'app'"
# Every instance calls its app service "app", so compose's service-name alias
# collides across the base stack and every instance. Both must carry a unique
# alias, and the proxy must target it - otherwise https://app.<domain> serves
# whichever container answers first.
dxenv
base="$(docker compose -f docker-compose.yml config 2>/dev/null)"
assert_contains "$base" "APP_UPSTREAM: main:" "the proxy targets 'main', not 'app'"
n="$(printf '%s' "$base" | grep -c '^ *- main$')"
[ "${n:-0}" -ge 2 ] && t_ok "the base app carries the 'main' alias on both networks" \
    || t_fail "the base app carries the 'main' alias on both networks" "found $n, want 2
"
inst="$(docker compose -f docker-compose.instance.yml --profile sandbox config 2>/dev/null)"
n="$(printf '%s' "$inst" | grep -c '^ *- probe$')"
[ "${n:-0}" -ge 2 ] && t_ok "an instance carries its slug alias on both networks" \
    || t_fail "an instance carries its slug alias on both networks" "found $n, want 2
"

t_section "instances get the same runtime settings as the base stack"
# A limit raised in config that applies to main and to nothing else presents as
# "it works on main but not on my branch".
for v in PHP_MEMORY_LIMIT PHP_OPCACHE_MEMORY DX_REQUEST_BODY_MAX; do
    assert_contains "$inst" "$v:" "instances receive \$$v"
done

t_section "the database engines never share a data directory"
# They did, and switching services.database then produced:
#   --initialize specified but the data directory has files in it. Aborting.
# - which names neither the cause nor the fix.
my="$(grep -oE '\./data/db[^:]*:/var/lib/mysql' docker-compose.yml | head -1)"
pg="$(grep -oE '\./data/db[^:]*:/var/lib/postgresql/data' docker-compose.yml | head -1)"
assert_ne "" "$my" "the mysql data mount is declared"
assert_ne "" "$pg" "the postgres data mount is declared"
assert_ne "${my%%:*}" "${pg%%:*}" "and they are different host directories"
assert_contains "$my" "data/db/mysql" "mysql has its own directory"
assert_contains "$pg" "data/db/postgres" "postgres has its own directory"

t_section "the isolated network is internal"
assert_contains "$(docker compose -f docker-compose.yml config 2>/dev/null)" "internal: true" \
    "no-egress is declared internal"

t_section "the app never runs as root, and a bare compose call fails"
dxenv
assert_contains "$(docker compose -f docker-compose.yml config 2>/dev/null)" "user: $(id -u):$(id -g)" \
    "containers run as the invoking user"
out="$(env -u HOST_UID -u HOST_GID docker compose -f docker-compose.yml config -q 2>&1)"; rc=$?
assert_ne "0" "$rc" "compose without HOST_UID fails rather than running as root"
assert_contains "$out" "run dx" "and the error names dx"

t_section "every example produces a valid compose file"
for f in examples/*/*.stack.yml; do
    # Each example points repo.root at its own project layout. That is correct
    # for the example and meaningless in a sandbox, so redirect it - the thing
    # under test is whether the rest of the file produces valid compose.
    sed -e 's|^  root: .*|  root: ..|' -e 's|^  git_root: .*|  git_root: ..|' \
        "$f" > config/stack.yml
    load_sandbox "$SB" local >/dev/null 2>&1
    dxenv
    pargs=(); [ "$DB_ENGINE" != none ] && pargs=(--profile "$DB_ENGINE")
    assert_ok "example $(basename "$f" .stack.yml)" \
        docker compose -f docker-compose.yml "${pargs[@]}" --profile redis config -q
done

t_summary

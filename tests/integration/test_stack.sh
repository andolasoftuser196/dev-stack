#!/usr/bin/env bash
# End-to-end against real Docker: build, serve, isolate, tear down.
#
# Opt-in (tests/run --integration) because it pulls images, builds a runtime and
# takes minutes. Everything it asserts is something the unit tests cannot: that
# the container actually starts, that the proxy actually routes, that the
# isolated network actually has no way out.
#
# It runs entirely in a temp directory with its own stack name and its own proxy
# ports, so it cannot disturb a stack you have running.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"

have_docker_daemon || { t_skip "integration" "no docker daemon"; t_summary; exit; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ssmdint.XXXXXX")"
STACK="ssmdit$$"
cleanup() {
    if [ -d "$WORK/dev-stack" ]; then
        ( cd "$WORK/dev-stack" && SSMD_YES=1 ./ssmd down >/dev/null 2>&1 )
    fi
    docker ps -aq --filter "label=ssmd.stack=$STACK" | xargs -r docker rm -f >/dev/null 2>&1
    docker network rm "${STACK}-dev" "${STACK}-dev-isolated" >/dev/null 2>&1
    docker image rm -f "${STACK}-dev/frankenphp:8.3" >/dev/null 2>&1
    # Container-written files are root-owned; remove them the way ssmd nuke does.
    docker run --rm -v "$WORK:/w" alpine:3 sh -c 'rm -rf /w/*' >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

t_section "fixture"
mkdir -p "$WORK/app/public" && ( cd "$WORK/app" && git init -q . )
cat > "$WORK/app/public/index.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo "instance=" . (getenv('SSMD_INSTANCE') ?: '?') . "\n";
echo "memory_limit=" . ini_get('memory_limit') . "\n";
try {
    new PDO("mysql:host=".getenv('DB_HOST').";port=".getenv('DB_PORT').";dbname=".getenv('DB_DATABASE'),
            getenv('DB_USERNAME'), getenv('DB_PASSWORD'));
    echo "db=" . getenv('DB_DATABASE') . " ok\n";
} catch (Throwable $e) { echo "db=FAILED\n"; }
$r = new Redis();
try { $r->connect(getenv('REDIS_HOST'), (int)getenv('REDIS_PORT')); $r->select((int)getenv('REDIS_DB'));
      echo "redis=" . getenv('REDIS_DB') . " ok\n"; } catch (Throwable $e) { echo "redis=FAILED\n"; }
PHP
echo '{"name":"ssmd/it"}' > "$WORK/app/composer.json"
( cd "$WORK/app" && git add -A && git -c user.name=t -c user.email=t@l commit -qm init )
t_ok "fixture application created"

tar -C "$TEST_ROOT" --exclude=./data --exclude=./.git --exclude=./tests \
    --exclude=./config/ssmd.db --exclude=./config/ssmd.db-wal --exclude=./config/ssmd.db-shm \
    --exclude=./.stack.env --exclude=__pycache__ -cf - . 2>/dev/null \
    | (mkdir -p "$WORK/dev-stack" && tar -C "$WORK/dev-stack" -xf -)
cd "$WORK/dev-stack"

python3 - "$STACK" <<'PY'
import pathlib, re, sys
name = sys.argv[1]
p = pathlib.Path("config/stack.yml"); s = p.read_text()
s = re.sub(r'^name: .*$', 'name: %s' % name, s, flags=re.M)
s = re.sub(r'^domain: .*$', 'domain: %s.test' % name, s, flags=re.M)
s = re.sub(r'^  root: \.\.$', '  root: ../app', s, flags=re.M)
s = re.sub(r'^  git_root: \.\.$', '  git_root: ../app', s, flags=re.M)
s = re.sub(r'^  worktree_root: .*$', '  worktree_root: ../worktrees', s, flags=re.M)
s = re.sub(r'^  framework: .*$', '  framework: none', s, flags=re.M)
s = s.replace('  queue: true', '  queue: false').replace('  scheduler: true', '  scheduler: false')
s = re.sub(r'^  name: .*$', '  name: %s_dev' % name, s, flags=re.M, count=1)
s = re.sub(r'^  user: .*$', '  user: %s' % name, s, flags=re.M, count=1)
s = re.sub(r'^  password: .*$', '  password: %s' % name, s, flags=re.M, count=1)
for h in ("postCreate", "postStart", "postInstance"):
    s = re.sub(r'  %s:\n(    - "[^"]*"\n)+' % h, '  %s: []\n' % h, s)
p.write_text(s)
# A host profile with ports nothing else on this machine will be using.
pathlib.Path("config/hosts.yml").write_text(pathlib.Path("config/hosts.yml").read_text() +
    "\nintegration:\n  proxy:\n    bind: 127.0.0.1\n    http: 18390\n    https: 18353\n"
    "  bind:\n    database: 127.0.0.1\n    cache: 127.0.0.1\n")
PY
printf 'SSMD_HOST=integration\n' > .env
t_ok "toolkit copied and configured"

t_section "ssmd up"
SSMD_YES=1 ./ssmd up core > "$WORK/up.log" 2>&1
rc=$?
[ $rc -eq 0 ] && t_ok "ssmd up core succeeded" || t_fail "ssmd up core succeeded" \
    "$(grep -vE '^#[0-9]+ ' "$WORK/up.log" | tail -25)
"
[ $rc -eq 0 ] || { t_summary; exit 1; }

assert_file "data/proxy/caddy/pki/authorities/local/root.crt" "the local CA was generated"
for svc in app proxy mysql redis; do
    docker ps --format '{{.Names}}' | grep -qx "${STACK}-dev-$svc" \
        && t_ok "$svc is running" || t_fail "$svc is running"
done

t_section "the app actually serves"
body="$(curl -sS --max-time 20 http://127.0.0.1:18390/ 2>&1)"
assert_contains "$body" "instance=main" "the catch-all route reaches the app"
assert_contains "$body" "db=${STACK}_dev ok" "the app reaches the database"
assert_contains "$body" "redis=0 ok" "the app reaches the cache"
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18390/healthz)"
assert_eq "200" "$code" "healthz is answered by the web server"

t_section "config drives the running container"
assert_contains "$body" "memory_limit=$(./ssmd config get php.memory_limit)" \
    "php.memory_limit reached PHP"
./ssmd config set php.memory_limit 321M >/dev/null
./ssmd recreate app >/dev/null 2>&1
until curl -sf http://127.0.0.1:18390/healthz >/dev/null 2>&1; do sleep 2; done
assert_contains "$(curl -sS http://127.0.0.1:18390/)" "memory_limit=321M" \
    "changing config and recreating changes the running process"

t_section "ssmd verify"
out="$(./ssmd verify 2>&1)"
assert_contains "$out" "healthz 200" "verify checks the web server"
assert_contains "$out" "database reachable from the app container" "verify checks the database from the app"
assert_contains "$out" "no error lines" "verify diffs the log"

t_section "worktree instance"
SSMD_YES=1 ./ssmd wt add feature/it > "$WORK/wt.log" 2>&1 \
    && t_ok "ssmd wt add succeeded" || t_fail "ssmd wt add succeeded" "$(tail -20 "$WORK/wt.log")
"
assert_contains "$(./ssmd wt ls)" "feature-it" "the instance is registered"
assert_file "caddy/proxy/sites/feature-it.caddy" "its proxy route exists"
ib="$(curl -sS --max-time 20 -H "Host: feature-it.${STACK}.test" http://127.0.0.1:18390/ 2>&1)"
assert_contains "$ib" "instance=feature-it" "the instance is routed by hostname"
assert_contains "$ib" "db=${STACK}_dev_feature_it ok" "with its own database"
assert_contains "$ib" "redis=1 ok" "and its own redis logical database"
# The regression this guards: every instance's app service also carries the
# compose alias "app", so the proxy round-robined and app.<domain> served
# whichever container answered first.
mb="$(curl -sS --max-time 20 -H "Host: app.${STACK}.test" http://127.0.0.1:18390/ 2>&1)"
assert_contains "$mb" "instance=main" "app.<domain> still reaches the base stack, not the instance"
assert_contains "$mb" "db=${STACK}_dev ok" "and the base stack's own database"
for _ in 1 2 3 4 5; do
    [ "$(curl -sS -H "Host: app.${STACK}.test" http://127.0.0.1:18390/ | head -1)" = "instance=main" ] \
        || { t_fail "app.<domain> is stable across repeated requests"; break; }
done
t_ok "app.<domain> is stable across repeated requests"
assert_contains "$ib" "memory_limit=321M" "the instance inherits the stack's runtime settings"

t_section "doctor detects injected drift"
docker stop "${STACK}-dev-wt-feature-it-app" >/dev/null 2>&1
out="$(./ssmd doctor 2>&1)"
assert_contains "$out" "registered but no container running" "a stopped instance is drift"
docker start "${STACK}-dev-wt-feature-it-app" >/dev/null 2>&1

t_section "teardown removes everything it made"
SSMD_YES=1 ./ssmd wt rm feature-it --drop-db > "$WORK/rm.log" 2>&1 \
    && t_ok "ssmd wt rm succeeded" || t_fail "ssmd wt rm succeeded" "$(tail -15 "$WORK/rm.log")
"
assert_no_file "caddy/proxy/sites/feature-it.caddy" "the route is gone"
assert_contains "$(./ssmd wt ls)" "no instances" "the registry is empty"
assert_ok "a pre-drop snapshot was kept" bash -c "ls data/snapshots/auto-predrop-* >/dev/null 2>&1"
docker ps -a --format '{{.Names}}' | grep -q "feature-it" \
    && t_fail "no instance containers remain" || t_ok "no instance containers remain"

t_section "destructive guards hold against a live database"
assert_fail "ssmd refuses to drop the development database" \
    env SSMD_YES=1 ./ssmd db:drop "${STACK}_dev"
assert_fail "ssmd refuses a non-disposable name" env SSMD_YES=1 ./ssmd db:drop production

t_section "ssmd down"
assert_ok "ssmd down succeeded" ./ssmd down
n="$(docker ps -q --filter "label=ssmd.stack=$STACK" | wc -l)"
assert_eq "0" "$n" "no containers left running"

t_summary

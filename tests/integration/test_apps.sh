#!/usr/bin/env bash
# Boot each demo app for real and assert the status contract holds.
#
# This is the test that makes `dx up` on a fresh clone a claim rather than a
# hope. Every app is booted through its own example config, served through the
# proxy, and asked the same question.
#
# Slow: each runtime builds an image and installs dependencies. Limit it while
# iterating:
#
#     DX_TEST_APPS="go php-plain" tests/run integration/test_apps
. "$(dirname "$(readlink -f "$0")")/../lib.sh"

have_docker_daemon || { t_skip "app boot" "no docker daemon"; t_summary; exit; }

# example stem : app : needs a dependency install : table its migration creates
#
# The last field is what makes "ships a migration" a claim rather than a hope: a
# hook that exits zero has proved nothing (Doctrine's --allow-no-migration exits
# zero with no migrations at all). The table either exists afterwards or it does
# not.
ALL="go-service:go:no:
frankenphp-plain:php-plain:yes:
node-plain:express:yes:
python-plain:python-plain:no:
frankenphp-laravel:laravel:yes:demo_notes
frankenphp-cakephp:cakephp:yes:demo_notes
frankenphp-symfony:symfony:yes:demo_notes
node-next:next:yes:
node-nest:nest:yes:
node-vite:vite:yes:
python-django:django:yes:demo_demonote
python-fastapi:fastapi:yes:demo_notes
python-flask:flask:yes:"

WANT="${DX_TEST_APPS:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxapps.XXXXXX")"
cleanup() {
    [ -d "$WORK/dev-stack" ] && ( cd "$WORK/dev-stack" && DX_YES=1 ./dx down >/dev/null 2>&1 )
    docker ps -aq --filter 'label=dx.managed=true' | xargs -r docker rm -f >/dev/null 2>&1
    docker run --rm -v "$WORK:/w" alpine:3 sh -c 'rm -rf /w/*' >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

tar -C "$TEST_ROOT" --exclude=./data --exclude=./.git --exclude=./tests \
    --exclude=./config/dx.db --exclude=./config/dx.db-wal --exclude=./config/dx.db-shm \
    --exclude=./.stack.env --exclude=__pycache__ --exclude=node_modules --exclude=vendor \
    -cf - . 2>/dev/null | (mkdir -p "$WORK/dev-stack" && tar -C "$WORK/dev-stack" -xf -)
cd "$WORK/dev-stack"
( cd .. && git init -q . && git add -A >/dev/null 2>&1 \
  && git -c user.name=t -c user.email=t@l commit -qm fixture >/dev/null 2>&1 ) || true

# One host profile for all of them, on ports nothing else here uses.
cat >> config/hosts.yml <<'Y'

apptest:
  proxy:
    bind: 127.0.0.1
    http: 18490
    https: 18453
  bind:
    database: 127.0.0.1
    cache: 127.0.0.1
Y
printf 'DX_HOST=apptest\n' > .env

boot_one() {
    local stem="$1" app="$2" table="${4:-}"
    t_section "$app  (examples/runtimes/$stem.stack.yml)"

    # Tear the previous app down, then make sure. `dx down` is the right thing
    # and it is not enough here: every app reuses one proxy port, so anything it
    # leaves behind makes the NEXT app fail with "port is already allocated" -
    # which reads like a broken app and is nothing of the kind.
    ( cd "$WORK/dev-stack" && DX_YES=1 ./dx down >/dev/null 2>&1 )
    docker ps -aq --filter 'label=dx.managed=true' | xargs -r docker rm -f >/dev/null 2>&1

    # And wait for the kernel to actually release it. Docker returns from `rm`
    # before the port is reusable, so a fast loop races it.
    local waited=0
    while ss -ltn 2>/dev/null | grep -q ':18490 '; do
        sleep 1; waited=$((waited+1))
        [ "$waited" -gt 30 ] && { t_fail "$app: port 18490 never freed"; return 1; }
    done

    # One sandbox serves every app, so the shared dependency cache carries the
    # previous one's installed packages into the next. A real project never hits
    # this - it has one app - but the test would otherwise report a python app as
    # working because the app before it installed the same framework.
    # Host-side for the user-owned caches; through a container only for the
    # database directory, which the engine writes as root.
    #
    # NOT `docker run -v .../data:/d` when data/ may not exist: docker creates a
    # missing bind-mount source as ROOT, and the app container - which runs as
    # the invoking user - then cannot write its cache at all.
    rm -rf "$WORK/dev-stack/data/build-cache" 2>/dev/null
    if [ -d "$WORK/dev-stack/data/db" ]; then
        docker run --rm -v "$WORK/dev-stack/data:/d" alpine:3 \
            sh -c 'rm -rf /d/db /d/cache' >/dev/null 2>&1
    fi
    # A distinct stack name per app: the derived port offset follows it, so two
    # runs cannot collide on the database port.
    sed -e "s|^name: .*|name: dxa${app//-/}|" \
        -e "s|^domain: .*|domain: dxa${app//-/}.test|" \
        "examples/runtimes/$stem.stack.yml" > config/stack.yml
    rm -f .stack.env config/dx.db*

    if ! DX_YES=1 ./dx up core > "$WORK/$app.log" 2>&1; then
        t_fail "$app: dx up" "$(grep -vE '^#[0-9]+ ' "$WORK/$app.log" | tail -20)
"
        return 1
    fi
    t_ok "$app: dx up"

    # Dependencies, where the app has any. Separate from `up` because a failure
    # here means "the install broke", not "the stack broke", and conflating them
    # sends people to the wrong place.
    if [ "$3" = yes ]; then
        if ./dx deps >> "$WORK/$app.log" 2>&1; then t_ok "$app: dx deps"
        else t_fail "$app: dx deps" "$(tail -15 "$WORK/$app.log")
"; return 1; fi
        ./dx recreate app >/dev/null 2>&1
    fi

    # Give the app process time to come up behind Caddy. healthz is Caddy's, so
    # it says nothing about the app - poll the app itself.
    local body="" i=0
    while [ $i -lt 45 ]; do
        body="$(curl -sS --max-time 10 http://127.0.0.1:18490/ 2>/dev/null)"
        case "$body" in *"dx demo app"*) break ;; esac
        sleep 2; i=$((i+2))
    done

    if ! printf '%s' "$body" | grep -qF 'dx demo app'; then
        # A blank page says nothing. The application log says what the process
        # actually did, and without it every one of these failures costs a
        # separate reproduction run.
        # Strip tags and squeeze blanks: a framework error page is mostly
        # markup, and five lines of <head> says nothing about what went wrong.
        t_fail "$app: serves the status page" "response was:
$(printf '%s' "$body" | sed -e 's/<[^>]*>/ /g' -e 's/  */ /g' \
    | grep -vE '^\s*$' | head -8 | cut -c1-160 | sed 's/^/  | /')

last 25 lines of the app container:
$(./dx logs app --tail 25 2>&1 | tail -25 | sed 's/^/  | /')
"
    else
        t_ok "$app: serves the status page"
    fi
    assert_contains "$body" "instance=main" "$app: reports its instance"
    assert_match "$body" 'runtime=[a-z]+ framework=' "$app: reports runtime and framework"

    # database=skipped is correct for the two apps configured without one.
    case "$body" in
        *"database=skipped"*) t_ok "$app: no database, as configured" ;;
        *"database="*" ok"*)  t_ok "$app: reached its database" ;;
        *) t_fail "$app: reached its database" "$body
" ;;
    esac
    case "$body" in
        *"cache=skipped"*) t_ok "$app: no cache, as configured" ;;
        *"cache=db"*"ok"*) t_ok "$app: reached its own redis logical database" ;;
        *) t_fail "$app: reached its cache" "$body
" ;;
    esac

    # healthz must be Caddy's, and must answer even though no app route defines it.
    local code; code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18490/healthz)"
    assert_eq "200" "$code" "$app: healthz answered by the web server"

    # The migration either produced a table or it did not. A hook exiting zero
    # is not evidence — Doctrine's --allow-no-migration exits zero having found
    # nothing at all, which is exactly the failure this catches.
    if [ -n "$table" ]; then
        local n
        n="$(./dx db:query "SELECT COUNT(*) FROM information_schema.tables
                             WHERE table_name = '$table'" 2>/dev/null | tr -cd '0-9')"
        [ "${n:-0}" -ge 1 ] \
            && t_ok "$app: its migration created '$table'" \
            || t_fail "$app: its migration created '$table'" "the table is not there.
tables present:
$(./dx db:query 'SELECT table_name FROM information_schema.tables
                  WHERE table_schema NOT IN (\'information_schema\',\'pg_catalog\',\'mysql\',\'sys\',\'performance_schema\')' 2>&1 | head -10 | sed 's/^/  | /')
"
    fi
    return 0
}

# Read the list into an array first.
#
# NOT `while read ... <<< "$ALL"`: boot_one runs docker and curl, both of which
# read stdin - which here IS the list. The first app consumes every remaining
# line, so the loop silently runs one entry and reports success for the rest by
# never reaching them. (The same bug, in the same shape, as the registry loops
# in lib/doctor.sh and lib/agent.sh.)
mapfile -t ROWS <<< "$ALL"

ran=0
for row in "${ROWS[@]}"; do
    [ -z "$row" ] && continue
    IFS=: read -r stem app deps table <<< "$row"
    [ -z "$stem" ] && continue
    if [ -n "$WANT" ]; then
        case " $WANT " in *" $app "*) ;; *) continue ;; esac
    fi
    boot_one "$stem" "$app" "$deps" "$table" || true
    ran=$((ran+1))
done

[ "$ran" -gt 0 ] || t_skip "app boot" "DX_TEST_APPS matched nothing"
t_summary

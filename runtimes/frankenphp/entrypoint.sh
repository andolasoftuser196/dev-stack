#!/bin/sh
# FrankenPHP runtime entrypoint. Roles: serve | queue | scheduler | idle.
set -eu

ROLE="${1:-${SSMD_ROLE:-serve}}"
: "${SSMD_PORT:=80}"
: "${SSMD_DOCROOT:=public}"
: "${SSMD_HEALTHZ:=/healthz}"
: "${SSMD_FRAMEWORK:=none}"
: "${SSMD_INSTANCE:=main}"
export SSMD_PORT SSMD_DOCROOT SSMD_HEALTHZ

say() { echo "[ssmd-entrypoint:$ROLE] $*"; }

# The container runs as the host UID, which has no /etc/passwd entry and so no
# home directory. Anything that expects one (composer, npm, git config) writes to
# $HOME from the image env; create it before it is needed rather than letting the
# first tool that wants it fail with a confusing EACCES.
# /ssmd/cache is a bind mount. If something created it with docker as root, this
# container - which runs as the invoking user - cannot write to it, and every
# tool that wants a home directory then fails in its own confusing way. Check
# once, here, and say what to do.
if ! mkdir -p "$HOME" 2>/dev/null || ! touch "$HOME/.ssmd-writable" 2>/dev/null; then
    say "/ssmd/cache is not writable by uid $(id -u) - it is probably root-owned."
    say "  ssmd fix-perms      (or: sudo chown -R \$(id -u) data/build-cache)"
    exit 1
fi
rm -f "$HOME/.ssmd-writable"

mkdir -p "$HOME" "$COMPOSER_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" 2>/dev/null || true

# Trust the stack's local CA so that server-side HTTP to https://*.$SSMD_DOMAIN
# validates. Without this an app calling its own public URL - webhooks,
# server-rendered previews, an S3 signed-URL fetch - fails with an
# unknown-authority error that reads like an application bug.
if [ -f /ssmd/ca/root.crt ] && [ ! -f /usr/local/share/ca-certificates/ssmd-local.crt ]; then
    if cp /ssmd/ca/root.crt /usr/local/share/ca-certificates/ssmd-local.crt 2>/dev/null; then
        update-ca-certificates >/dev/null 2>&1 || true
        say "installed stack CA into the system trust store"
    else
        # Non-root, which is the normal case. Point PHP's client at the file
        # directly instead; curl and the stream wrappers both honour it.
        export CURL_CA_BUNDLE=/ssmd/ca/root.crt
        export SSL_CERT_FILE=/ssmd/ca/root.crt
        say "stack CA available at /ssmd/ca/root.crt (not root; using CURL_CA_BUNDLE)"
    fi
fi

# Xdebug's ini interpolates these; empty values there produce a startup warning
# on every single command, which quickly trains people to ignore warnings.
export XDEBUG_MODE="${XDEBUG_MODE:-off}"
export XDEBUG_CLIENT_HOST="${XDEBUG_CLIENT_HOST:-$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')}"
export XDEBUG_CLIENT_HOST="${XDEBUG_CLIENT_HOST:-172.17.0.1}"

wait_for_deps() {
    # A worker that starts before its database is up dies, gets restarted by
    # compose, and does that a dozen times before the database is ready - filling
    # the log with failures that have nothing to do with the code.
    [ "${DB_HOST:-}" = "" ] && return 0
    i=0
    while [ "$i" -lt 60 ]; do
        if php -r 'exit(@fsockopen(getenv("DB_HOST"), (int)getenv("DB_PORT"), $e, $s, 1) ? 0 : 1);' 2>/dev/null; then
            return 0
        fi
        i=$((i+1)); sleep 1
    done
    say "database ${DB_HOST}:${DB_PORT} did not become reachable in 60s - continuing anyway"
}

framework_queue_cmd() {
    case "$SSMD_FRAMEWORK" in
        laravel) echo "php artisan queue:work --sleep=1 --tries=${QUEUE_TRIES:-3} --timeout=${QUEUE_TIMEOUT:-120} --max-time=${WORKER_MAX_RUNTIME:-1800}" ;;
        cakephp) echo "bin/cake queue worker --max-runtime=${WORKER_MAX_RUNTIME:-1800}" ;;
        symfony) echo "php bin/console messenger:consume async --time-limit=${WORKER_MAX_RUNTIME:-1800}" ;;
        *)       echo "" ;;
    esac
}

framework_schedule_cmd() {
    case "$SSMD_FRAMEWORK" in
        laravel) echo "php artisan schedule:run" ;;
        cakephp) echo "bin/cake scheduler run" ;;
        symfony) echo "php bin/console app:scheduler" ;;
        *)       echo "" ;;
    esac
}

case "$ROLE" in
    serve)
        say "frankenphp $(php -r 'echo PHP_VERSION;') serving /app/${SSMD_DOCROOT} on :${SSMD_PORT} (instance ${SSMD_INSTANCE})"
        exec frankenphp run --config /etc/caddy/Caddyfile
        ;;

    queue)
        cmd="$(framework_queue_cmd)"
        [ -n "$cmd" ] || { say "framework '$SSMD_FRAMEWORK' has no queue worker - set services.queue: false"; exit 1; }
        wait_for_deps
        say "$cmd"
        # No exec: the worker is deliberately restarted in a loop rather than
        # left to compose. A worker that exits because it hit --max-time is
        # healthy, and letting compose treat that as a crash makes the restart
        # backoff grow until the queue stops draining.
        while true; do
            sh -c "$cmd" || say "worker exited $? - restarting in 3s"
            sleep 3
        done
        ;;

    scheduler)
        cmd="$(framework_schedule_cmd)"
        [ -n "$cmd" ] || { say "framework '$SSMD_FRAMEWORK' has no scheduler - set services.scheduler: false"; exit 1; }
        wait_for_deps
        say "running '$cmd' every 60s"
        while true; do
            sh -c "$cmd" || say "scheduler tick exited $?"
            sleep 60
        done
        ;;

    idle)
        say "idle"
        exec tail -f /dev/null
        ;;

    *)
        # Anything else is run verbatim, which is what `ssmd exec` relies on.
        exec "$@"
        ;;
esac

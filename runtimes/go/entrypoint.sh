#!/bin/sh
# Go runtime entrypoint. Roles: serve | queue | scheduler | idle.
set -eu

ROLE="${1:-${DX_ROLE:-serve}}"
: "${DX_PORT:=80}"
: "${DX_APP_PORT:=8080}"
: "${DX_HEALTHZ:=/healthz}"
export DX_PORT DX_APP_PORT DX_HEALTHZ PORT="${DX_APP_PORT}"

say() { echo "[dx-entrypoint:$ROLE] $*"; }

# /dx/cache is a bind mount. If something created it with docker as root, this
# container - which runs as the invoking user - cannot write to it, and every
# tool that wants a home directory then fails in its own confusing way. Check
# once, here, and say what to do.
if ! mkdir -p "$HOME" 2>/dev/null || ! touch "$HOME/.dx-writable" 2>/dev/null; then
    say "/dx/cache is not writable by uid $(id -u) - it is probably root-owned."
    say "  dx fix-perms      (or: sudo chown -R \$(id -u) data/build-cache)"
    exit 1
fi
rm -f "$HOME/.dx-writable"

mkdir -p "$HOME" "$GOPATH" "$GOCACHE" "$GOMODCACHE" /dx/cache/air 2>/dev/null || true

if [ -f /dx/ca/root.crt ]; then
    export SSL_CERT_FILE=/dx/ca/root.crt
fi

# Use the project's own .air.toml when it has one - a project that has tuned its
# watch rules knows its layout better than the default here does.
AIR_CFG=/dx/air.toml
[ -f /app/.air.toml ] && AIR_CFG=/app/.air.toml

# Every command below runs in a plain shell, never `sh -lc`.
#
# A login shell sources /etc/profile, which on Debian resets PATH
# unconditionally — dropping the virtualenv, /usr/local/go/bin, and node's
# global bin. The process then dies with "flask: not found" inside a container
# where flask is demonstrably installed, and the entrypoint restarts it forever.
case "$ROLE" in
    serve)
        say "caddy on :${DX_PORT} -> go on :${DX_APP_PORT} (air, config ${AIR_CFG})"
        caddy run --config /etc/caddy/Caddyfile &
        exec air -c "$AIR_CFG" ;;
    queue)
        cmd="${DX_QUEUE_CMD:-go run ./cmd/worker}"
        while true; do sh -c "$cmd" || say "worker exited $?"; sleep 3; done ;;
    scheduler)
        cmd="${DX_SCHEDULE_CMD:-go run ./cmd/scheduler}"
        while true; do sh -c "$cmd" || say "scheduler tick exited $?"; sleep 60; done ;;
    idle) exec tail -f /dev/null ;;
    *)    exec "$@" ;;
esac

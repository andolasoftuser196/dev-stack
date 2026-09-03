#!/bin/sh
# Go runtime entrypoint. Roles: serve | queue | scheduler | idle.
set -eu

ROLE="${1:-${SSMD_ROLE:-serve}}"
: "${SSMD_PORT:=80}"
: "${SSMD_APP_PORT:=8080}"
: "${SSMD_HEALTHZ:=/healthz}"
export SSMD_PORT SSMD_APP_PORT SSMD_HEALTHZ PORT="${SSMD_APP_PORT}"

say() { echo "[ssmd-entrypoint:$ROLE] $*"; }

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

mkdir -p "$HOME" "$GOPATH" "$GOCACHE" "$GOMODCACHE" /ssmd/cache/air 2>/dev/null || true

if [ -f /ssmd/ca/root.crt ]; then
    export SSL_CERT_FILE=/ssmd/ca/root.crt
fi

# Use the project's own .air.toml when it has one - a project that has tuned its
# watch rules knows its layout better than the default here does.
AIR_CFG=/ssmd/air.toml
[ -f /app/.air.toml ] && AIR_CFG=/app/.air.toml

# Every command below runs in a plain shell, never `sh -lc`.
#
# A login shell sources /etc/profile, which on Debian resets PATH
# unconditionally — dropping the virtualenv, /usr/local/go/bin, and node's
# global bin. The process then dies with "flask: not found" inside a container
# where flask is demonstrably installed, and the entrypoint restarts it forever.
case "$ROLE" in
    serve)
        say "caddy on :${SSMD_PORT} -> go on :${SSMD_APP_PORT} (air, config ${AIR_CFG})"
        caddy run --config /etc/caddy/Caddyfile &
        exec air -c "$AIR_CFG" ;;
    queue)
        cmd="${SSMD_QUEUE_CMD:-go run ./cmd/worker}"
        while true; do sh -c "$cmd" || say "worker exited $?"; sleep 3; done ;;
    scheduler)
        cmd="${SSMD_SCHEDULE_CMD:-go run ./cmd/scheduler}"
        while true; do sh -c "$cmd" || say "scheduler tick exited $?"; sleep 60; done ;;
    idle) exec tail -f /dev/null ;;
    *)    exec "$@" ;;
esac

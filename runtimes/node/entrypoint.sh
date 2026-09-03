#!/bin/sh
# Node runtime entrypoint. Roles: serve | queue | scheduler | idle.
set -eu

ROLE="${1:-${DX_ROLE:-serve}}"
: "${DX_PORT:=80}"
: "${DX_APP_PORT:=3000}"
: "${DX_HEALTHZ:=/healthz}"
: "${DX_FRAMEWORK:=none}"
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

mkdir -p "$HOME" "$NPM_CONFIG_CACHE" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" 2>/dev/null || true

if [ -f /dx/ca/root.crt ]; then
    # Node ignores the system trust store; NODE_EXTRA_CA_CERTS is the only knob
    # that makes https to *.$DX_DOMAIN validate from inside the app.
    export NODE_EXTRA_CA_CERTS=/dx/ca/root.crt
fi

pm() {
    # Respect the project's declared package manager. Guessing wrong regenerates
    # a lockfile in a different format, which is a diff nobody wants to review.
    if [ -f /app/pnpm-lock.yaml ];      then echo pnpm
    elif [ -f /app/yarn.lock ];         then echo yarn
    elif [ -f /app/bun.lockb ];         then echo bun
    else                                     echo npm
    fi
}

dev_cmd() {
    case "$DX_FRAMEWORK" in
        next)  echo "$(pm) run dev -- --port ${DX_APP_PORT} --hostname 0.0.0.0" ;;
        nest)  echo "$(pm) run start:dev" ;;
        vite)  echo "$(pm) run dev -- --port ${DX_APP_PORT} --host 0.0.0.0" ;;
        *)     echo "${DX_START_CMD:-$(pm) run dev}" ;;
    esac
}

# Every command below runs in a plain shell, never `sh -lc`.
#
# A login shell sources /etc/profile, which on Debian resets PATH
# unconditionally — dropping the virtualenv, /usr/local/go/bin, and node's
# global bin. The process then dies with "flask: not found" inside a container
# where flask is demonstrably installed, and the entrypoint restarts it forever.
case "$ROLE" in
    serve)
        say "caddy on :${DX_PORT} -> node on :${DX_APP_PORT} ($(pm), framework ${DX_FRAMEWORK})"
        caddy run --config /etc/caddy/Caddyfile &
        CADDY_PID=$!
        # Restart the app process on exit but leave Caddy alone, so healthz - and
        # therefore the container - survives a crash loop in application code.
        while true; do
            sh -c "$(dev_cmd)" || say "app exited $? - restarting in 2s"
            kill -0 "$CADDY_PID" 2>/dev/null || { say "caddy died; exiting"; exit 1; }
            sleep 2
        done
        ;;
    queue)
        cmd="${DX_QUEUE_CMD:-$(pm) run queue}"
        say "$cmd"
        while true; do sh -c "$cmd" || say "worker exited $?"; sleep 3; done ;;
    scheduler)
        cmd="${DX_SCHEDULE_CMD:-$(pm) run schedule}"
        while true; do sh -c "$cmd" || say "scheduler tick exited $?"; sleep 60; done ;;
    idle) exec tail -f /dev/null ;;
    *)    exec "$@" ;;
esac

#!/bin/sh
# Python runtime entrypoint. Roles: serve | queue | scheduler | idle.
set -eu

ROLE="${1:-${DX_ROLE:-serve}}"
: "${DX_PORT:=80}"
: "${DX_APP_PORT:=8000}"
: "${DX_HEALTHZ:=/healthz}"
: "${DX_FRAMEWORK:=none}"
export DX_PORT DX_APP_PORT DX_HEALTHZ

say() { echo "[dx-entrypoint:$ROLE] $*"; }

mkdir -p "$HOME" "$PIP_CACHE_DIR" "$UV_CACHE_DIR" 2>/dev/null || true

# A venv on the bind-mounted cache rather than in /app: site-packages inside the
# repo tree confuses every editor's indexer, and a venv baked into the image is
# lost on rebuild. This survives both.
#
# One per instance ($DX_VENV ends in the instance name). Sharing it meant two
# branches with different dependencies overwrote each other, and the loser
# failed with ModuleNotFoundError for something in its own manifest.
: "${DX_VENV:=/dx/cache/venv/${DX_INSTANCE:-main}}"
export VIRTUAL_ENV="$DX_VENV"
export PATH="$DX_VENV/bin:$PATH"
if [ ! -d "$DX_VENV" ]; then
    if ! uv venv "$DX_VENV" >/dev/null 2>&1 && ! python -m venv "$DX_VENV" >/dev/null 2>&1; then
        # Almost always /dx/cache being root-owned: something created it with
        # docker as root, and this container runs as the invoking user. Under
        # `set -e` this used to exit silently, so compose restarted the container
        # forever and the only visible symptom was "container is restarting".
        say "cannot create a virtualenv at $DX_VENV"
        say "  /dx/cache must be writable by uid $(id -u). If it is root-owned:"
        say "      dx fix-perms          (or: sudo chown -R \$(id -u) data/build-cache)"
        exit 1
    fi
fi

if [ -f /dx/ca/root.crt ]; then
    # requests/httpx read these; certifi's bundle does not include a local CA.
    export SSL_CERT_FILE=/dx/ca/root.crt
    export REQUESTS_CA_BUNDLE=/dx/ca/root.crt
fi

# Only export the framework's own variables when an override was actually set.
#
# Compose cannot omit a key conditionally, so an unset override arrives as "" -
# and an empty DJANGO_SETTINGS_MODULE is worse than an absent one, because
# os.environ.setdefault() in manage.py will not replace it. Django then starts
# with no settings and reports something entirely unrelated.
[ -n "${DX_SETTINGS_MODULE:-}" ] && export DJANGO_SETTINGS_MODULE="$DX_SETTINGS_MODULE"

app_cmd() {
    case "$DX_FRAMEWORK" in
        django)  echo "python manage.py runserver 127.0.0.1:${DX_APP_PORT}" ;;
        fastapi) echo "uvicorn ${DX_ASGI_APP:-app.main:app} --reload --host 127.0.0.1 --port ${DX_APP_PORT}" ;;
        flask)   echo "flask --app ${DX_WSGI_APP:-app} run --debug --host 127.0.0.1 --port ${DX_APP_PORT}" ;;
        *)       echo "${DX_START_CMD:-python -m http.server ${DX_APP_PORT} --bind 127.0.0.1}" ;;
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
        say "caddy on :${DX_PORT} -> python on :${DX_APP_PORT} (${DX_FRAMEWORK})"
        caddy run --config /etc/caddy/Caddyfile &
        while true; do sh -c "$(app_cmd)" || say "app exited $? - restarting in 2s"; sleep 2; done ;;
    queue)
        cmd="${DX_QUEUE_CMD:-celery -A ${DX_CELERY_APP:-app} worker -l info}"
        say "$cmd"
        while true; do sh -c "$cmd" || say "worker exited $?"; sleep 3; done ;;
    scheduler)
        cmd="${DX_SCHEDULE_CMD:-celery -A ${DX_CELERY_APP:-app} beat -l info}"
        exec sh -c "$cmd" ;;
    idle) exec tail -f /dev/null ;;
    *)    exec "$@" ;;
esac

#!/usr/bin/env bash
# `dx init` - scaffold a dev-stack for a project.
#
# This is the one command that needs Python, and it is deliberately the only one.
# Scaffolding happens once; daily operations happen a hundred times a day, and
# they must work on a box with nothing but bash and docker - which is exactly the
# box you are on when the stack is already broken.
#
# The venv lives in scaffold/.venv and is created on first use. If you would
# rather not have one, install jinja2 and pyyaml yourself and dx will use them.
set -euo pipefail

DX_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VENV="$DX_ROOT/scaffold/.venv"

have_deps() {
    "$1" -c 'import jinja2, yaml' >/dev/null 2>&1
}

PY=""
if command -v python3 >/dev/null 2>&1 && have_deps python3; then
    PY=python3
elif [ -x "$VENV/bin/python" ] && have_deps "$VENV/bin/python"; then
    PY="$VENV/bin/python"
else
    command -v python3 >/dev/null 2>&1 \
        || { echo "[dx init] ERROR: python3 is required for 'dx init' (and only for it)." >&2
             echo "          Every other dx command needs nothing but bash and docker." >&2
             exit 1; }
    echo "[dx init] creating scaffold venv at scaffold/.venv (once)"
    python3 -m venv "$VENV" >/dev/null 2>&1 \
        || { echo "[dx init] ERROR: could not create a venv. On Debian/Ubuntu:" >&2
             echo "            sudo apt install python3-venv" >&2
             exit 1; }
    "$VENV/bin/pip" install --quiet --disable-pip-version-check \
        -r "$DX_ROOT/scaffold/requirements.txt"
    PY="$VENV/bin/python"
fi

exec "$PY" "$DX_ROOT/scaffold/scaffold.py" --dx-root "$DX_ROOT" "$@"

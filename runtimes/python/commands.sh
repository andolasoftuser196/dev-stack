# runtimes/python/commands.sh - ssmd verbs for Python projects.

rt_display_name() { echo "Python ${STACK_RUNTIME_VERSION} (${STACK_RUNTIME_FRAMEWORK})"; }
rt_verbs() { echo "python pip uv manage pytest ruff alembic celery"; }

# NOT `sh -lc`. A login shell sources /etc/profile, which on Debian sets PATH
# unconditionally - clobbering everything the image added. The go toolchain
# (/usr/local/go/bin) and the python venv (/ssmd/cache/venv/bin) both vanish, and
# the symptom is `go: not found` in a container that plainly has go in it.
#
# `docker exec` already applies the image's ENV, so a plain shell has the right
# PATH and a login shell is strictly worse.
# `docker exec` starts a fresh process that never runs the entrypoint, so the
# venv the entrypoint activated is not on this process's PATH. Activate it
# explicitly - otherwise `ssmd deps` installs into the system python and the app,
# which uses the venv, still cannot import anything.
_py_in() { rt_exec "$@"; }

# The venv existing is not enough - the entrypoint creates an empty one at boot.
# Something has to be installed in it.
# The venv existing is not enough - the entrypoint creates an empty one at boot.
# Something has to be installed in it.
rt_deps_present() {
    dexec "$(container app)" sh -c \
        'V="${SSMD_VENV:-/ssmd/cache/venv/${SSMD_INSTANCE:-main}}"
         ls -A "$V/lib"/python*/site-packages 2>/dev/null | grep -qv "^_"' \
        >/dev/null 2>&1
}

rt_deps_install() {
    # Lockfile first, in order of how precisely each pins.
    #
    # --active throughout: the venv lives at $VIRTUAL_ENV on the shared cache
    # mount, not at ./.venv in the repo. Without the flag uv ignores the active
    # environment, creates a second one inside the bind-mounted source tree, and
    # installs there - so the app still cannot import anything, and the only clue
    # is a warning in the middle of a successful-looking install.
    if   [ -f "$APP_DIR/uv.lock" ]; then
        _py_in app "uv sync --active --frozen"

    elif [ -f "$APP_DIR/poetry.lock" ]; then
        _py_in app "pip install poetry && poetry install --no-root"

    elif [ -f "$APP_DIR/requirements.lock" ]; then
        _py_in app "uv pip install -r requirements.lock"

    elif [ -f "$APP_DIR/requirements.txt" ]; then
        # Not itself a lockfile unless it is fully pinned, but it is what the
        # project declared, so it is installed as-is rather than second-guessed.
        _py_in app "uv pip install -r requirements.txt"

    elif [ -f "$APP_DIR/pyproject.toml" ]; then
        warn "no lockfile in $APP_DIR - resolving from pyproject.toml"
        hint "the result is not reproducible; commit the uv.lock this writes."
        _py_in app "uv sync --active"

    else
        die "no dependency manifest at $APP_DIR (looked for uv.lock, poetry.lock,
      requirements.txt, pyproject.toml)"
    fi
}

rt_migrate() {
    case "${STACK_RUNTIME_FRAMEWORK}" in
        django) _py_in app "python manage.py migrate --noinput" ;;
        *)      if [ -f "$APP_DIR/alembic.ini" ]; then _py_in app "alembic upgrade head"
                else log "no migration tool detected (django, alembic)"; fi ;;
    esac
}

rt_test() {
    local test_db="${DB_NAME}$(_cfg DATABASE_SAFETY_TEST_SUFFIX)"
    # The disposable-database check lives in lib/db.sh and reads its patterns
    # from config, so every runtime enforces the same rule and widening it is a
    # deliberate, visible config change rather than an edit to one language's
    # commands.sh that the others never get.
    db_matches_patterns "$test_db" DATABASE_SAFETY_TEST_PATTERN || die \
        "refusing to run tests against '$test_db' - it does not match
      database_safety.test_pattern ($(_cfg DATABASE_SAFETY_TEST_PATTERN)).
      Nothing in ssmd will point a suite that truncates tables at a database you
      might care about."
    db_create_database "$test_db"
    audit "test.run" "db=$test_db"
    # Django appends its own test_ prefix; passing --keepdb would defeat the
    # isolation, so it is deliberately not offered here.
    dexec -e DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-config.settings}" \
          -e DB_DATABASE="$test_db" \
          -e DATABASE_URL="$(_cfgd DB_URL_SCHEME postgresql)://${DB_USER}:${DB_PASSWORD}@${DB_ENGINE}:${DB_INTERNAL_PORT}/${test_db}" \
          "$(container app)" sh -c "pytest ${*:-}"
}

rt_lint() {
    if [ -f "$APP_DIR/ruff.toml" ] || grep -q '\[tool.ruff\]' "$APP_DIR/pyproject.toml" 2>/dev/null; then
        _py_in app "ruff check --fix ${*:-.} && ruff format ${*:-.}"
    else _py_in app "python -m ruff check ${*:-.}"; fi
}

rt_repl() {
    case "${STACK_RUNTIME_FRAMEWORK}" in
        django) _py_in app "python manage.py shell" ;;
        *)      _py_in app "python" ;;
    esac
}

rt_dispatch() {
    local verb="$1"; shift || true
    case "$verb" in
        python|pip|uv|pytest|ruff|alembic|celery) _py_in app "$verb $*" ;;
        manage) _py_in app "python manage.py $*" ;;
        *) return 1 ;;
    esac
}

rt_doctor_notes() {
    [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/requirements.txt" ] \
        || warn "no pyproject.toml or requirements.txt at $APP_DIR - is repo.root right?"
}

# Run a command in a container, in the environment the runtime needs.
#
# Not just `dexec sh -c`: `docker exec` starts a process that never ran the
# entrypoint, so anything the entrypoint set up is absent. For python that is
# the virtualenv, and the symptom is `ModuleNotFoundError: No module named
# 'django'` immediately after a successful install — because the install went to
# the venv and the hook ran outside it.
#
# Every caller that runs a project command goes through this: hooks, ssmd run,
# ssmd exec, and the per-instance equivalents.
rt_exec() {
    local svc="$1"; shift
    dexec "$(container "$svc")" sh -c \
        'V="${SSMD_VENV:-/ssmd/cache/venv/${SSMD_INSTANCE:-main}}"
         [ -d "$V" ] && { export VIRTUAL_ENV="$V" PATH="$V/bin:$PATH"; }
         exec sh -c "$1"' _ "$*"
}

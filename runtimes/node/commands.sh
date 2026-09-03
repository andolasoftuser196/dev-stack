# runtimes/node/commands.sh - dx verbs for Node projects.

rt_display_name() { echo "Node ${STACK_RUNTIME_VERSION} (${STACK_RUNTIME_FRAMEWORK})"; }
rt_verbs() { echo "npm pnpm yarn npx node vite next nest tsc"; }

# NOT `sh -lc`. A login shell sources /etc/profile, which on Debian sets PATH
# unconditionally - clobbering everything the image added. The go toolchain
# (/usr/local/go/bin) and the python venv (/dx/cache/venv/bin) both vanish, and
# the symptom is `go: not found` in a container that plainly has go in it.
#
# `docker exec` already applies the image's ENV, so a plain shell has the right
# PATH and a login shell is strictly worse.
_node_in() { rt_exec "$@"; }

_pm() {
    if   [ -f "$APP_DIR/pnpm-lock.yaml" ]; then echo pnpm
    elif [ -f "$APP_DIR/yarn.lock" ];      then echo yarn
    elif [ -f "$APP_DIR/bun.lockb" ];      then echo bun
    else                                        echo npm
    fi
}

rt_deps_present() { dexec "$(container app)" sh -c 'test -d /app/node_modules' >/dev/null 2>&1; }

rt_deps_install() {
    local m; m="$(_pm)"

    # No lockfile: `npm ci` fails with its own usage text, which says nothing
    # about the actual problem. Say what is wrong, do the non-frozen install so
    # the stack still comes up, and be explicit that the result is not
    # reproducible.
    if ! _has_lockfile; then
        warn "no lockfile in $APP_DIR - installing without one"
        hint "the result is not reproducible: another machine may resolve different"
        hint "versions. Commit the lockfile this produces, then 'dx deps' is frozen."
        _node_in app "$m install"
        return
    fi

    # The frozen-lockfile form for each manager. A dev stack that silently
    # updates a lockfile produces a diff the developer did not ask for and did
    # not read.
    case "$m" in
        pnpm) _node_in app "pnpm install --frozen-lockfile" ;;
        yarn) _node_in app "yarn install --immutable || yarn install --frozen-lockfile" ;;
        bun)  _node_in app "bun install --frozen-lockfile" ;;
        *)    _node_in app "npm ci" ;;
    esac
}

_has_lockfile() {
    [ -f "$APP_DIR/package-lock.json" ] || [ -f "$APP_DIR/pnpm-lock.yaml" ] \
        || [ -f "$APP_DIR/yarn.lock" ] || [ -f "$APP_DIR/bun.lockb" ]
}

rt_migrate() {
    if   [ -f "$APP_DIR/prisma/schema.prisma" ]; then _node_in app "npx prisma migrate deploy"
    elif [ -f "$APP_DIR/drizzle.config.ts" ];    then _node_in app "npx drizzle-kit migrate"
    elif grep -q '"migrate"' "$APP_DIR/package.json" 2>/dev/null; then _node_in app "$(_pm) run migrate"
    else log "no migration tool detected (looked for prisma, drizzle, a 'migrate' script)"; fi
}

rt_test() {
    # Node suites rarely truncate a shared database, but the ones using
    # testcontainers or a real Postgres do. Same rule as everywhere in dx: point
    # them at the disposable database, never the development one.
    local test_db="${DB_NAME}$(_cfg DATABASE_SAFETY_TEST_SUFFIX)"
    # The disposable-database check lives in lib/db.sh and reads its patterns
    # from config, so every runtime enforces the same rule and widening it is a
    # deliberate, visible config change rather than an edit to one language's
    # commands.sh that the others never get.
    db_matches_patterns "$test_db" DATABASE_SAFETY_TEST_PATTERN || die \
        "refusing to run tests against '$test_db' - it does not match
      database_safety.test_pattern ($(_cfg DATABASE_SAFETY_TEST_PATTERN)).
      Nothing in dx will point a suite that truncates tables at a database you
      might care about."
    db_create_database "$test_db"
    audit "test.run" "db=$test_db"
    dexec -e NODE_ENV=test -e DB_DATABASE="$test_db" \
          -e DATABASE_URL="$(_cfgd DB_URL_SCHEME mysql)://${DB_USER}:${DB_PASSWORD}@${DB_ENGINE}:${DB_INTERNAL_PORT}/${test_db}" \
          "$(container app)" sh -c "$(_pm) test ${*:-}"
}

rt_lint() {
    if grep -q '"lint"' "$APP_DIR/package.json" 2>/dev/null; then _node_in app "$(_pm) run lint ${*:-}"
    else _node_in app "npx --yes eslint . ${*:-}"; fi
}

rt_repl() { _node_in app "node"; }

rt_dispatch() {
    local verb="$1"; shift || true
    case "$verb" in
        npm|pnpm|yarn|npx|node|tsc) _node_in app "$verb $*" ;;
        vite) _node_in app "npx vite $*" ;;
        next) _node_in app "npx next $*" ;;
        nest) _node_in app "npx nest $*" ;;
        *) return 1 ;;
    esac
}

rt_doctor_notes() {
    [ -f "$APP_DIR/package.json" ] || warn "no package.json at $APP_DIR - is repo.root right?"
    local m; m="$(_pm)"
    case "$m" in
        pnpm) [ -f "$APP_DIR/pnpm-lock.yaml" ] || warn "pnpm selected but no pnpm-lock.yaml" ;;
        npm)  [ -f "$APP_DIR/package-lock.json" ] || warn "no package-lock.json - 'npm ci' will fail; run 'dx exec app npm install' once" ;;
    esac
}

# Run a command in a container, in the environment the runtime needs.
#
# Not just `dexec sh -c`: `docker exec` starts a process that never ran the
# entrypoint, so anything the entrypoint set up is absent. For python that is
# the virtualenv, and the symptom is `ModuleNotFoundError: No module named
# 'django'` immediately after a successful install — because the install went to
# the venv and the hook ran outside it.
#
# Every caller that runs a project command goes through this: hooks, dx run,
# dx exec, and the per-instance equivalents.
rt_exec() { local svc="$1"; shift; dexec "$(container "$svc")" sh -c "$*"; }

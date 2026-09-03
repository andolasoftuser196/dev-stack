# runtimes/go/commands.sh - dx verbs for Go projects.

rt_display_name() { echo "Go ${STACK_RUNTIME_VERSION}"; }
rt_verbs() { echo "go air dlv staticcheck migrate"; }

# NOT `sh -lc`. A login shell sources /etc/profile, which on Debian sets PATH
# unconditionally - clobbering everything the image added. The go toolchain
# (/usr/local/go/bin) and the python venv (/dx/cache/venv/bin) both vanish, and
# the symptom is `go: not found` in a container that plainly has go in it.
#
# `docker exec` already applies the image's ENV, so a plain shell has the right
# PATH and a login shell is strictly worse.
_go_in() { rt_exec "$@"; }

rt_deps_present() { dexec "$(container app)" sh -c 'test -d "$GOMODCACHE/cache"' >/dev/null 2>&1; }

rt_deps_install() {
    # `go mod download` and not `go mod tidy`: tidy rewrites go.mod and go.sum,
    # and a dev stack must not produce a diff the developer did not ask for.
    _go_in app "go mod download"
}

rt_migrate() {
    if   [ -d "$APP_DIR/migrations" ] && command -v migrate >/dev/null 2>&1; then
        _go_in app "migrate -path ./migrations -database \"\$DATABASE_URL\" up"
    elif [ -f "$APP_DIR/cmd/migrate/main.go" ]; then
        _go_in app "go run ./cmd/migrate up"
    else log "no migration tool detected (golang-migrate, ./cmd/migrate)"; fi
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
      Nothing in dx will point a suite that truncates tables at a database you
      might care about."
    db_create_database "$test_db"
    audit "test.run" "db=$test_db"
    # -count=1 defeats Go's test result cache. A cached PASS after an edit that
    # did not touch the package is correct in principle and deeply confusing in
    # practice when you are trying to see a change take effect.
    dexec -e DB_DATABASE="$test_db" \
          -e DATABASE_URL="$(_cfgd DB_URL_SCHEME postgres)://${DB_USER}:${DB_PASSWORD}@${DB_ENGINE}:${DB_INTERNAL_PORT}/${test_db}?sslmode=disable" \
          "$(container app)" sh -c "go test -count=1 ${*:-./...}"
}

rt_lint() { _go_in app "gofmt -l -w . && go vet ./... && staticcheck ./... ${*:-}"; }
rt_repl() { die "Go has no REPL. 'dx sh' gives you a shell in the app container."; }

rt_dispatch() {
    local verb="$1"; shift || true
    case "$verb" in
        go|air|dlv|staticcheck|migrate) _go_in app "$verb $*" ;;
        *) return 1 ;;
    esac
}

rt_doctor_notes() {
    [ -f "$APP_DIR/go.mod" ] || warn "no go.mod at $APP_DIR - is repo.root right?"
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

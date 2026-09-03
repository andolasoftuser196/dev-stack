# runtimes/frankenphp/commands.sh - dx verbs for PHP projects.
# Sourced by dx. See runtimes/_contract.md.

rt_display_name() { echo "FrankenPHP ${STACK_RUNTIME_VERSION} (${STACK_RUNTIME_FRAMEWORK})"; }

rt_verbs() { echo "composer artisan cake console php phpunit pint phpstan tinker"; }

# NOT `sh -lc`. A login shell sources /etc/profile, which on Debian sets PATH
# unconditionally - clobbering everything the image added. The go toolchain
# (/usr/local/go/bin) and the python venv (/dx/cache/venv/bin) both vanish, and
# the symptom is `go: not found` in a container that plainly has go in it.
#
# `docker exec` already applies the image's ENV, so a plain shell has the right
# PATH and a login shell is strictly worse.
_php_in() { rt_exec "$@"; }

rt_deps_present() {
    dexec "$(container app)" sh -c 'test -f /app/vendor/autoload.php' >/dev/null 2>&1
}

rt_deps_install() {
    # `install`, never `update`. The lockfile is the contract; resolving it afresh
    # in a dev stack is how a machine ends up running dependency versions no CI
    # run has ever seen - and how a compromised package gets pulled in on a box
    # where nobody was watching the diff.
    if [ ! -f "$APP_DIR/composer.lock" ]; then
        warn "no composer.lock in $APP_DIR - this install will resolve fresh"
        hint "the result is not reproducible; commit the lockfile it writes."
    else
        log "composer install (from composer.lock)"
    fi
    _php_in app "composer install --no-interaction --prefer-dist --no-progress"
}

rt_migrate() {
    case "${STACK_RUNTIME_FRAMEWORK}" in
        laravel) _php_in app "php artisan migrate --force" ;;
        cakephp) _php_in app "bin/cake migrations migrate" ;;
        symfony) _php_in app "php bin/console doctrine:migrations:migrate --no-interaction" ;;
        *) log "framework '${STACK_RUNTIME_FRAMEWORK}' has no migration command - skipping" ;;
    esac
}

# The safety-critical one. See runtimes/_contract.md: a suite that reads the
# development connection and then truncates it is a documented, repeatedly-hit
# failure, not a hypothetical. Two independent guards:
#
#   1. The database name is forced to <db>_test here, in the environment, so it
#      is right even if phpunit.xml's own <env> block is commented out - which it
#      was, in the stack this lesson came from.
#   2. dx refuses to proceed if that name does not match the disposable pattern.
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

    log "ensuring test database '$test_db' exists"
    db_create_database "$test_db"

    local cmd
    case "${STACK_RUNTIME_FRAMEWORK}" in
        laravel) cmd="php artisan test ${*:-}" ;;
        cakephp) cmd="vendor/bin/phpunit ${*:-}" ;;
        symfony) cmd="php bin/phpunit ${*:-}" ;;
        *)       cmd="vendor/bin/phpunit ${*:-}" ;;
    esac

    audit "test.run" "db=$test_db cmd=$cmd"
    dexec \
        -e DB_DATABASE="$test_db" \
        -e DB_CONNECTION="${DB_TEST_CONNECTION:-${DB_ENGINE}}" \
        -e APP_ENV=testing \
        -e CACHE_DRIVER=array \
        -e SESSION_DRIVER=array \
        -e QUEUE_CONNECTION=sync \
        "$(container app)" sh -c "$cmd"
}

rt_lint() {
    if dexec "$(container app)" sh -c 'test -x vendor/bin/pint' >/dev/null 2>&1; then
        _php_in app "vendor/bin/pint ${*:-}"
    elif dexec "$(container app)" sh -c 'test -x vendor/bin/php-cs-fixer' >/dev/null 2>&1; then
        _php_in app "vendor/bin/php-cs-fixer fix ${*:-}"
    else
        die "no formatter found (looked for vendor/bin/pint, vendor/bin/php-cs-fixer)"
    fi
}

rt_repl() {
    case "${STACK_RUNTIME_FRAMEWORK}" in
        laravel) _php_in app "php artisan tinker" ;;
        cakephp) _php_in app "bin/cake console" ;;
        *)       _php_in app "php -a" ;;
    esac
}

rt_dispatch() {
    local verb="$1"; shift || true
    case "$verb" in
        composer)
            # Deliberately no `dx composer update`. A lockfile pin is often the
            # only thing holding a project away from a compromised release, and
            # `update` re-resolves it silently. If you genuinely need to update,
            # do it knowingly with `dx exec app composer update` and read the
            # diff before committing it.
            case "${1:-}" in
                update|require|remove)
                    die "'composer $1' rewrites the lockfile.
      dx will not do that for you, because the diff needs a human. If you mean it:
        dx exec app composer $*
      then review composer.lock before committing." ;;
            esac
            _php_in app "composer $*" ;;
        artisan)  _php_in app "php artisan $*" ;;
        cake)     _php_in app "bin/cake $*" ;;
        console)  _php_in app "php bin/console $*" ;;
        php)      _php_in app "php $*" ;;
        phpunit)  rt_test "$@" ;;
        pint)     rt_lint "$@" ;;
        tinker)   rt_repl ;;
        phpstan)
            _php_in app "vendor/bin/phpstan analyse --memory-limit=${PHPSTAN_MEMORY} $*" ;;
        *) return 1 ;;
    esac
}

# Framework-specific advice `dx doctor` prints when something looks off. Kept
# with the runtime rather than in doctor.sh so that adding a framework does not
# mean editing a file in lib/.
rt_doctor_notes() {
    [ -f "$APP_DIR/composer.json" ] || warn "no composer.json at $APP_DIR - is repo.root right?"
    if [ "${STACK_RUNTIME_FRAMEWORK}" = "laravel" ] && [ -f "$APP_DIR/.env" ]; then
        grep -qE '^APP_KEY=.+' "$APP_DIR/.env" \
            || fail "../.env has no APP_KEY - every read of an encrypted column will throw.
             Note that changing an existing APP_KEY breaks an imported database's
             encrypted columns; generate it once, then leave it alone."
    fi
    if [ -d "$APP_DIR/storage" ] && [ -n "$(find "$APP_DIR/storage" ! -user "$HOST_UID" -print -quit 2>/dev/null)" ]; then
        warn "root-owned files under storage/ - 'dx fix-perms' repairs them"
    fi
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

# lib/sqlite.sh - the one place that talks to the config store.
#
# Config lives in SQLite. That is a genuine dependency, and this file is the
# concession that keeps it from becoming a hard one: three backends, picked once
# per invocation, cheapest first.
#
#   sqlite3(1)   fastest, ~2ms per call. Not installed by default on Debian
#                minimal images or macOS without the CLI tools.
#   python3      present essentially everywhere, and already required by the
#                Claude Code hooks. ~40ms per call - the startup cost of the
#                interpreter, not the query.
#   docker       last resort, ~250ms per call. Present by definition: without
#                docker there is no stack to configure.
#
# The cost difference between the first and last is 100x, which would matter a
# great deal if ssmd read the database on every command. It does not: config is
# resolved once into a flat .stack.env cache (lib/config.sh) and every subsequent
# ssmd invocation reads that file. SQLite is touched only when configuration
# actually changes, which is rare. That caching is what makes the dependency
# affordable, and it is why the cache is not an optimisation to be removed later.

SSMD_SQLITE_BACKEND=""

sqlite_backend() {
    [ -n "$SSMD_SQLITE_BACKEND" ] && { echo "$SSMD_SQLITE_BACKEND"; return 0; }
    if command -v sqlite3 >/dev/null 2>&1; then
        SSMD_SQLITE_BACKEND=cli
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' 2>/dev/null; then
        SSMD_SQLITE_BACKEND=python
    elif command -v docker >/dev/null 2>&1; then
        SSMD_SQLITE_BACKEND=docker
    else
        die "no way to read the config database.
      ssmd needs one of: sqlite3(1), python3 with the sqlite3 module, or docker.
      Install sqlite3 - it is a few hundred kilobytes and makes ssmd noticeably
      faster:
        Debian/Ubuntu  sudo apt install sqlite3
        macOS          brew install sqlite"
    fi
    echo "$SSMD_SQLITE_BACKEND"
}

# The field separator for every row this file returns.
#
# NOT tab. Tab is an IFS whitespace character, and bash's `read` collapses runs
# of IFS whitespace and strips it from both ends - so an empty column silently
# disappears and every field after it shifts left by one. That produced history
# rows reading "removed (was X)" for what was actually an insert, and it would
# have produced far worse in the instance registry.
#
# U+001F UNIT SEPARATOR is non-whitespace, so `read` preserves empty fields, and
# it cannot occur in a config value, a path or a branch name.
SSMD_FS=$'\x1f'

# Run SQL against the config database. Rows come back SSMD_FS-separated, no header.
#
# SQL arrives on stdin rather than as an argument so that a value containing a
# quote, a newline or a semicolon cannot end the statement early. Every caller in
# lib/config.sh builds statements with sq_quote(), never by interpolating raw
# user input.
# PRAGMA foreign_keys is per CONNECTION, not per database. Setting it once in
# schema.sql applies only to the connection that ran the schema - every later
# call opens a fresh one with it OFF, so ON DELETE CASCADE silently never fires
# and a removed instance leaves its lease behind forever. -cmd runs it before
# the SQL on stdin, on every connection.
sq() {
    local db="${SSMD_DB_PATH:?config database path not set}"
    case "$(sqlite_backend)" in
        cli)
            # `PRAGMA foreign_keys=ON` in its setter form returns no rows.
            # `PRAGMA busy_timeout=N` DOES return one - it would prefix "5000"
            # to the result of every single query, which is exactly as
            # entertaining to debug as it sounds. `.timeout` is the silent form.
            sqlite3 -batch -noheader -separator "$SSMD_FS" \
                    -cmd "PRAGMA foreign_keys=ON" \
                    -cmd ".timeout 5000" "$db" ;;
        python)
            python3 "$SSMD_ROOT/lib/ssmddb.py" "$db" ;;
        docker)
            # -i so stdin reaches the container; the database directory is
            # mounted rather than the file, because SQLite writes -wal and -shm
            # siblings and a single-file mount makes those land in the container.
            docker run --rm -i \
                -v "$(cd "$(dirname "$db")" && pwd):/db" \
                --entrypoint sh keinos/sqlite3:latest \
                -c "sqlite3 -batch -noheader -separator \$'\\x1f' -cmd 'PRAGMA foreign_keys=ON' /db/$(basename "$db")" ;;
    esac
}

# Single scalar, or empty. The common read.
sq1() { sq | head -n1; }

# SQL string literal. Doubling the single quote is SQLite's own escape, and it is
# the only one it accepts - backslash escaping silently does the wrong thing.
sq_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

sqlite_init() {
    local db="${SSMD_DB_PATH:?}"
    mkdir -p "$(dirname "$db")"
    if [ ! -f "$db" ]; then
        log "creating config database at $db"
    fi
    # Idempotent: the schema is all CREATE TABLE IF NOT EXISTS, so this runs on
    # every init without needing a migration table for the initial shape.
    sq < "$SSMD_ROOT/config/schema.sql" >/dev/null
}

# True when the store exists and has been populated. Used to decide whether this
# is a first run that needs seeding.
sqlite_ready() {
    [ -f "${SSMD_DB_PATH:-}" ] || return 1
    local n
    n="$(printf "SELECT COUNT(*) FROM config;" | sq1 2>/dev/null)" || return 1
    [ "${n:-0}" -gt 0 ]
}

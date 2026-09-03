# lib/db.sh - database operations, engine-agnostic at the call site.
#
# Every function here dispatches on $DB_ENGINE. Callers (dx, runtimes, agent
# sandboxes) never learn which engine is running, which is what lets a runtime
# module like runtimes/go/commands.sh call db_create_database without caring
# whether it is talking to MySQL or Postgres.
#
# The destructive operations share one rule, and it is the most important thing
# in this file: **anything that can lose data takes a snapshot first**, and if
# the snapshot fails, the destructive operation does not run. Leaving a database
# intact is always recoverable; losing it because the safety net silently failed
# is not.

db_container() { container "$DB_ENGINE"; }

db_require() {
    [ "$DB_ENGINE" = "none" ] && die "this project has no database (stack.yml: services.database: none)"
    require_running "$DB_ENGINE"
}

# Internal port, for connection strings built inside the network.
# Set by core.sh from ports.<engine> in config. Kept as a function because
# runtimes and doctor call it, and a function is one place to change.
db_internal_port() { printf '%s' "${DB_INTERNAL_PORT:-0}"; }

# Does <name> match one of the patterns in <config key>? The patterns are a
# space-separated glob list, and {db} expands to the development database - so
# a project renaming its database does not silently widen what dx will drop.
db_matches_patterns() {  # <name> <CONFIG_SUFFIX>
    local name="$1" pat
    for pat in $(_cfg "$2"); do
        pat="${pat//\{db\}/$DB_NAME}"
        case "$name" in $pat) return 0 ;; esac
    done
    return 1
}

db_disposable_patterns() { _cfg DATABASE_SAFETY_DISPOSABLE | sed "s/{db}/$DB_NAME/g"; }

# ── raw SQL ─────────────────────────────────────────────────────────────────
# -i without -t: these are used from scripts and from the MCP server as often as
# from a terminal, and asking for a TTY where there is none is a hard error.
db_sql() {  # db_sql <sql> [database]
    local sql="$1" dbname="${2:-$DB_NAME}"
    case "$DB_ENGINE" in
        mysql)
            docker exec -i "$(db_container)" \
                mysql -uroot -p"$DB_PASSWORD" --batch --skip-column-names \
                ${dbname:+"$dbname"} -e "$sql" ;;
        postgres)
            docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$(db_container)" \
                psql -U "$DB_USER" -d "${dbname:-postgres}" -tAq -c "$sql" ;;
        *) die "no database engine configured" ;;
    esac
}

db_shell() {
    db_require
    case "$DB_ENGINE" in
        mysql)    dexec "$(db_container)" mysql -uroot -p"$DB_PASSWORD" "$DB_NAME" ;;
        postgres) dexec -e PGPASSWORD="$DB_PASSWORD" "$(db_container)" psql -U "$DB_USER" -d "$DB_NAME" ;;
    esac
}

db_exists() {  # db_exists <name>
    case "$DB_ENGINE" in
        mysql)
            [ -n "$(db_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1'" "" 2>/dev/null)" ] ;;
        postgres)
            [ "$(db_sql "SELECT 1 FROM pg_database WHERE datname='$1'" postgres 2>/dev/null | tr -d '[:space:]')" = "1" ] ;;
    esac
}

db_create_database() {  # db_create_database <name>
    local name="$1"
    db_require
    db_exists "$name" && return 0
    log "creating database '$name'"
    case "$DB_ENGINE" in
        mysql)
            db_sql "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" ""
            db_sql "GRANT ALL PRIVILEGES ON \`$name\`.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES" "" ;;
        postgres)
            db_sql "CREATE DATABASE \"$name\" OWNER \"$DB_USER\"" postgres ;;
    esac
    audit "db.create" "$name"
}

# The one function in dx that can destroy a database. Every caller goes through
# it, and it refuses outright on anything that does not look disposable.
db_drop_database() {  # db_drop_database <name> [--no-snapshot]
    local name="$1" snap=1
    [ "${2:-}" = "--no-snapshot" ] && snap=0
    db_require

    # The pattern check is a backstop, not the primary control. The primary
    # control is that nothing in dx ever passes the development database name
    # here - but a backstop is what stands between a shell typo and a bad day.
    if [ "$name" = "$DB_NAME" ]; then
        die "refusing to drop '$name' - that is this stack's development database.
      If you really mean it: dx nuke  (which at least says what it is doing)"
    fi
    db_matches_patterns "$name" DATABASE_SAFETY_DISPOSABLE || die \
        "refusing to drop '$name' - it does not match a disposable pattern.
      Allowed: $(db_disposable_patterns)
      Widen it deliberately if you must:
        dx config set database_safety.disposable \"<patterns>\""

    [ "$(_cfg DATABASE_SAFETY_SNAPSHOT_BEFORE_DESTROY)" = "true" ] || snap=0

    if [ "$snap" = 1 ] && db_exists "$name"; then
        # If the snapshot fails, the drop does not happen. This ordering is the
        # whole safety property; do not "improve" it by making the snapshot
        # best-effort.
        db_snapshot "$name" "auto-predrop" \
            || die "pre-drop snapshot of '$name' failed - not dropping.
      Investigate, then re-run with --no-snapshot if you accept the loss."
    fi

    log "dropping database '$name'"
    case "$DB_ENGINE" in
        mysql)    db_sql "DROP DATABASE IF EXISTS \`$name\`" "" ;;
        postgres)
            # Postgres refuses to drop a database with live connections, and the
            # app's pool reconnects instantly - so terminate first, in the same
            # breath, or this races forever.
            db_sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$name' AND pid <> pg_backend_pid()" postgres >/dev/null
            db_sql "DROP DATABASE IF EXISTS \"$name\"" postgres ;;
    esac
    audit "db.drop" "$name"
}

# ── snapshots ───────────────────────────────────────────────────────────────
# Snapshots are the provisioning mechanism, not just the backup mechanism. A new
# worktree or agent sandbox restoring a 200MB dump in 20 seconds is the
# difference between spinning one up casually and avoiding it.
db_snapshot() {  # db_snapshot [database] [label]
    local name="${1:-$DB_NAME}" label="${2:-manual}" ts file
    db_require
    ensure_dirs
    ts="$(date -u +%Y%m%d-%H%M%S)"
    file="data/snapshots/${label}-${name}-${ts}.sql.gz"

    log "snapshot ${name} -> ${file}"
    case "$DB_ENGINE" in
        mysql)
            # --single-transaction gives a consistent dump without locking the
            # tables, which matters because the app is usually still running.
            # --no-tablespaces avoids needing PROCESS on MySQL 8.
            docker exec "$(db_container)" mysqldump -uroot -p"$DB_PASSWORD" \
                --single-transaction --quick --no-tablespaces \
                --routines --triggers --events "$name" 2>/dev/null | gzip > "$file" ;;
        postgres)
            docker exec -e PGPASSWORD="$DB_PASSWORD" "$(db_container)" \
                pg_dump -U "$DB_USER" --no-owner --no-acl "$name" | gzip > "$file" ;;
    esac

    # A dump that failed halfway still leaves a valid gzip of a truncated file,
    # so size is the only cheap signal that it is real. 100 bytes is far below
    # any genuine schema and far above an empty gzip header.
    if [ ! -s "$file" ] || [ "$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")" -lt 100 ]; then
        rm -f "$file"; fail "snapshot produced no data - removed"; return 1
    fi
    ok "$(du -h "$file" | cut -f1)  $file"
    audit "db.snapshot" "$name -> $file"
}

db_restore() {  # db_restore <snapshot-file> [database]
    local file="$1" name="${2:-$DB_NAME}"
    [ -f "$file" ] || file="data/snapshots/$1"
    [ -f "$file" ] || die "snapshot not found: $1"
    db_require

    # Restoring is destructive to whatever is there now, so it gets the same
    # treatment as a drop: snapshot first, abort if that fails.
    if db_exists "$name"; then
        db_snapshot "$name" "auto-prerestore" \
            || die "pre-restore snapshot failed - not restoring over '$name'"
    fi

    log "restoring $file -> $name"
    db_create_database "$name"
    case "$DB_ENGINE" in
        mysql)    gunzip -c "$file" | docker exec -i "$(db_container)" mysql -uroot -p"$DB_PASSWORD" "$name" ;;
        postgres) gunzip -c "$file" | docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$(db_container)" psql -U "$DB_USER" -d "$name" -q ;;
    esac
    ok "restored"
    audit "db.restore" "$file -> $name"
}

db_snapshots_list() {
    ensure_dirs
    if [ -z "$(ls -A data/snapshots 2>/dev/null)" ]; then
        echo "  (none yet - dx db:snapshot)"
        return 0
    fi
    ls -lh data/snapshots/*.sql.gz 2>/dev/null | awk '{printf "  %-10s %s %s %s  %s\n", $5, $6, $7, $8, $9}'
}

db_table_count() {  # db_table_count [database]
    local name="${1:-$DB_NAME}"
    case "$DB_ENGINE" in
        mysql)    db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$name'" "" 2>/dev/null | tr -d '[:space:]' ;;
        postgres) db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" "$name" 2>/dev/null | tr -d '[:space:]' ;;
    esac
}

# Called at the end of `dx up`. An empty database is the single most common
# reason a fresh stack 500s, and the fix is not discoverable from the error.
db_warn_if_empty() {
    [ "$DB_ENGINE" = none ] && return 0
    local n; n="$(db_table_count)" || return 0
    [ -z "$n" ] && return 0
    [ "$n" != "0" ] && return 0
    cat <<EOF

  ! Database '${DB_NAME}' has no tables - the app will not work yet.

      dx db:migrate                     build it from the project's migrations
      dx db:restore <snapshot.sql.gz>   load a snapshot (dx db:snapshots lists them)
      dx db:import  <file.sql[.gz]>     load a dump from elsewhere
EOF
}

db_import() {  # db_import <file.sql|file.sql.gz> [database]
    local file="$1" name="${2:-$DB_NAME}"
    [ -f "$file" ] || die "not found: $file"
    db_require
    db_exists "$name" && { db_snapshot "$name" "auto-preimport" || die "pre-import snapshot failed"; }
    db_create_database "$name"
    log "importing $file -> $name"
    case "$file" in
        *.gz) gunzip -c "$file" ;;
        *)    cat "$file" ;;
    esac | case "$DB_ENGINE" in
        mysql)    docker exec -i "$(db_container)" mysql -uroot -p"$DB_PASSWORD" "$name" ;;
        postgres) docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$(db_container)" psql -U "$DB_USER" -d "$name" -q ;;
    esac
    ok "imported ($(db_table_count "$name") tables)"
    audit "db.import" "$file -> $name"
}

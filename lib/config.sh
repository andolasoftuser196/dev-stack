# lib/config.sh - the configuration layer.
#
# All configuration lives in a SQLite database. Nothing in ssmd, lib/, the compose
# files or the runtime images may hardcode a value that belongs to a project or
# a machine; if a number or an image tag appears in code, it is a bug and the
# value belongs in config/defaults.yml.
#
# Three layers, resolved highest-first:
#
#   host:<name>   config/hosts.yml     this machine     (SSMD_HOST selects one)
#   stack         config/stack.yml     this project
#   default       config/defaults.yml  the toolkit
#
# The YAML files are *seeds*, not the runtime source of truth. They exist so
# configuration is diffable, reviewable and committable; the database is what ssmd
# reads, and `ssmd config set` changes it without touching a file. Editing a seed
# re-imports it automatically (keyed on mtime), and `ssmd config export` writes the
# database back out so a runtime change can be committed.
#
# Why a database rather than the files directly:
#   - `ssmd config set` works at runtime, from a script, or over MCP, with no
#     YAML round-trip and no risk of reformatting someone's comments away.
#   - Every change is recorded in config_history with an actor, so "it worked
#     yesterday" and "did the agent change this" are one query each.
#   - The instance registry, leases and audit trail live in the same store, so
#     "what is going on" has one answer rather than four files to reconcile.
#
# Why a flat cache on top: ssmd runs dozens of times an hour and must stay fast and
# usable when things are broken. Resolution happens once into .stack.env; every
# subsequent invocation sources that file and never opens the database. The cache
# is invalidated by database mtime, so it is never stale.

CONFIG_CACHE=".stack.env"
CONFIG_SEEDS="config/defaults.yml config/stack.yml config/hosts.yml"

# ── import ──────────────────────────────────────────────────────────────────

_config_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Import one seed file into one scope. Rows the file no longer contains are
# deleted from that scope, so removing a key from a seed removes it from the
# database - otherwise a deleted line would linger forever and the file would
# stop describing reality.
config_import_file() {  # <path> <scope> [strip_first_segment]
    local path="$1" scope="$2" strip="${3:-0}"
    [ -f "$path" ] || return 0

    local sql; sql="$(mktemp)"
    {
        echo "BEGIN;"
        # A staging table rather than deleting first: if the file fails to parse
        # halfway, the transaction rolls back and the previous configuration is
        # still there. Deleting first would leave the stack unconfigured.
        echo "CREATE TEMP TABLE incoming(key TEXT PRIMARY KEY, value TEXT);"

        local key value host
        while IFS=$'\t' read -r key value; do
            [ -z "$key" ] && continue
            if [ "$strip" = "1" ]; then
                # hosts.yml nests everything under the machine name: the first
                # segment is the scope, the rest is the key.
                host="${key%%.*}"
                [ "$host" = "$key" ] && continue      # a bare top-level key is the map itself
                [ "host:$host" = "$scope" ] || continue
                key="${key#*.}"
            fi
            printf 'INSERT OR REPLACE INTO incoming VALUES(%s,%s);\n' \
                "$(sq_quote "$key")" "$(sq_quote "$value")"
        done < <(awk -v mode=dotted -f "$SSMD_ROOT/lib/yaml.awk" "$path" 2>/dev/null)

        # Record what actually changed before overwriting, so history is a diff
        # rather than a restatement of the whole file on every import.
        cat <<EOF
INSERT INTO config_history(ts, actor, scope, key, old_value, new_value)
SELECT $(sq_quote "$(_config_now)"), $(sq_quote "${SSMD_ACTOR:-${USER:-unknown}}"),
       $(sq_quote "$scope"), i.key, c.value, i.value
  FROM incoming i LEFT JOIN config c ON c.scope = $(sq_quote "$scope") AND c.key = i.key
 WHERE c.value IS NULL OR c.value <> i.value;

INSERT INTO config_history(ts, actor, scope, key, old_value, new_value)
SELECT $(sq_quote "$(_config_now)"), $(sq_quote "${SSMD_ACTOR:-${USER:-unknown}}"),
       $(sq_quote "$scope"), c.key, c.value, NULL
  FROM config c WHERE c.scope = $(sq_quote "$scope")
   AND c.key NOT IN (SELECT key FROM incoming);

DELETE FROM config WHERE scope = $(sq_quote "$scope")
   AND key NOT IN (SELECT key FROM incoming);

INSERT OR REPLACE INTO config(scope, key, value, origin, updated)
SELECT $(sq_quote "$scope"), key, value, 'import', $(sq_quote "$(_config_now)") FROM incoming;

INSERT OR REPLACE INTO seed_imports(path, scope, mtime, imported)
VALUES($(sq_quote "$path"), $(sq_quote "$scope"), $(_config_mtime "$path"), $(sq_quote "$(_config_now)"));

DROP TABLE incoming;
COMMIT;
EOF
    } > "$sql"

    sq < "$sql" >/dev/null || { rm -f "$sql"; die "importing $path into scope '$scope' failed"; }
    rm -f "$sql"
}

_config_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Which host scopes hosts.yml defines. Read from the file rather than from a
# list somewhere, so adding a machine is a one-place edit.
config_host_scopes() {
    awk -v mode=dotted -f "$SSMD_ROOT/lib/yaml.awk" config/hosts.yml 2>/dev/null \
        | cut -d. -f1 | sort -u
}

# Re-import any seed whose mtime has moved. Cheap: three stat calls and one
# query when nothing changed.
config_sync_seeds() {
    local changed=0 f recorded actual
    for f in $CONFIG_SEEDS; do
        [ -f "$f" ] || continue
        actual="$(_config_mtime "$f")"
        recorded="$(printf 'SELECT mtime FROM seed_imports WHERE path=%s;' "$(sq_quote "$f")" | sq1)"
        [ "${recorded:-0}" = "$actual" ] && continue
        changed=1
        case "$f" in
            */defaults.yml) config_import_file "$f" default ;;
            */stack.yml)    config_import_file "$f" stack ;;
            */hosts.yml)
                local h
                for h in $(config_host_scopes); do
                    config_import_file "$f" "host:$h" 1
                done
                # hosts.yml is imported once per scope; record it once.
                printf 'INSERT OR REPLACE INTO seed_imports VALUES(%s,%s,%s,%s);\n' \
                    "$(sq_quote "$f")" "'host:*'" "$actual" "$(sq_quote "$(_config_now)")" | sq >/dev/null
                ;;
        esac
    done
    return $changed
}

# ── resolution ──────────────────────────────────────────────────────────────
# One query does the layering. Ordering by an explicit rank rather than by scope
# name means adding a fourth layer later is a change to this CASE and nothing
# else.
config_resolve_sql() {
    cat <<EOF
SELECT key, value FROM (
  SELECT key, value,
         ROW_NUMBER() OVER (
           PARTITION BY key
           ORDER BY CASE scope
                      WHEN $(sq_quote "host:${SSMD_HOST:-local}") THEN 1
                      WHEN 'stack' THEN 2
                      WHEN 'default' THEN 3
                      ELSE 9 END
         ) AS rank
    FROM config
   WHERE scope IN ($(sq_quote "host:${SSMD_HOST:-local}"), 'stack', 'default')
) WHERE rank = 1 ORDER BY key;
EOF
}

# Turn a dotted key into the shell variable ssmd and compose read.
_config_varname() {
    printf 'STACK_%s' "$(printf '%s' "$1" | tr '[:lower:].-' '[:upper:]__')"
}

config_build_cache() {
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/ssmd-cache.XXXXXX")"
    {
        echo "# Generated from the config database. Do not edit - 'ssmd config set' instead."
        echo "# host=${SSMD_HOST:-local}  generated=$(_config_now)"
        local key value
        while IFS="$SSMD_FS" read -r key value; do
            [ -z "$key" ] && continue
            # The importer escaped embedded newlines to keep one row per line;
            # restore them so multi-line values (every hooks: list) come back
            # intact.
            value="$(printf '%b' "${value//\\n/\\n}")"
            printf "%s='%s'\n" "$(_config_varname "$key")" "${value//\'/\'\\\'\'}"
        done < <(config_resolve_sql | sq)
    } > "$tmp"

    # Write into place only when it worked. A half-written cache sources as a
    # truncated configuration, which fails much later and much less obviously.
    if [ ! -s "$tmp" ]; then rm -f "$tmp"; die "config resolution produced nothing - is the database seeded? try: ssmd config import"; fi

    if ! mv "$tmp" "$CONFIG_CACHE" 2>/dev/null; then
        # Read-only toolkit (an agent sandbox mounts /ssmd ro). Keep the resolved
        # cache in the temp directory instead of failing: an agent must still be
        # able to run ssmd from inside its sandbox.
        CONFIG_CACHE="$tmp"
    fi
}

config_cache_stale() {
    [ -f "$CONFIG_CACHE" ] || return 0
    [ "$SSMD_DB_PATH" -nt "$CONFIG_CACHE" ] && return 0
    local f
    for f in $CONFIG_SEEDS; do [ -f "$f" ] && [ "$f" -nt "$CONFIG_CACHE" ] && return 0; done
    # A different SSMD_HOST resolves differently, and the cache does not know that
    # by mtime alone - so it records which host it was built for.
    grep -q "^# host=${SSMD_HOST:-local} " "$CONFIG_CACHE" 2>/dev/null || return 0
    return 1
}

config_load() {
    sqlite_init
    if ! sqlite_ready; then
        log "first run - seeding configuration from config/*.yml"
        config_import_file config/defaults.yml default
        config_import_file config/stack.yml stack
        local h
        for h in $(config_host_scopes); do config_import_file config/hosts.yml "host:$h" 1; done
    else
        config_sync_seeds || true
    fi

    config_cache_stale && config_build_cache
    set -a; . "$CONFIG_CACHE"; set +a
}

# ── the ssmd config verbs ─────────────────────────────────────────────────────

config_get() {  # <key>
    local key="$1"
    [ -n "$key" ] || die "usage: ssmd config get <key>"
    local v; v="$(config_resolve_sql | sq | awk -F"$SSMD_FS" -v k="$key" '$1==k {print $2; exit}')"
    [ -n "$v" ] || { echo "(unset)" >&2; return 1; }
    printf '%s\n' "$v"
}

config_set() {  # <key> <value> [--scope stack|default|host:<n>]
    local key="$1" value="$2" scope="${3:-stack}"
    [ -n "$key" ] || die "usage: ssmd config set <key> <value> [scope]"
    case "$scope" in stack|default|host:*) ;; *) die "scope must be stack, default or host:<name>" ;; esac

    local old; old="$(printf 'SELECT value FROM config WHERE scope=%s AND key=%s;' \
                      "$(sq_quote "$scope")" "$(sq_quote "$key")" | sq1)"
    cat <<EOF | sq >/dev/null
BEGIN;
INSERT INTO config_history(ts, actor, scope, key, old_value, new_value)
VALUES($(sq_quote "$(_config_now)"), $(sq_quote "${SSMD_ACTOR:-${USER:-unknown}}"),
       $(sq_quote "$scope"), $(sq_quote "$key"), $( [ -n "$old" ] && sq_quote "$old" || echo NULL ), $(sq_quote "$value"));
INSERT OR REPLACE INTO config(scope, key, value, origin, updated)
VALUES($(sq_quote "$scope"), $(sq_quote "$key"), $(sq_quote "$value"), 'set', $(sq_quote "$(_config_now)"));
COMMIT;
EOF
    rm -f "$CONFIG_CACHE"
    ok "$scope: $key = $value${old:+   (was $old)}"
    hint "this is now out of step with config/$( [ "$scope" = default ] && echo defaults || echo "${scope%%:*}" ).yml - 'ssmd config export' writes it back"
}

config_unset() {  # <key> [scope]
    local key="$1" scope="${2:-stack}"
    local old; old="$(printf 'SELECT value FROM config WHERE scope=%s AND key=%s;' \
                      "$(sq_quote "$scope")" "$(sq_quote "$key")" | sq1)"
    [ -n "$old" ] || die "$scope has no '$key' to unset (ssmd config explain $key)"
    # Recorded, like every other change. A removal nobody can attribute is the
    # one people spend longest chasing.
    cat <<EOF | sq >/dev/null
BEGIN;
INSERT INTO config_history(ts, actor, scope, key, old_value, new_value)
VALUES($(sq_quote "$(_config_now)"), $(sq_quote "${SSMD_ACTOR:-unknown}"),
       $(sq_quote "$scope"), $(sq_quote "$key"), $(sq_quote "$old"), NULL);
DELETE FROM config WHERE scope=$(sq_quote "$scope") AND key=$(sq_quote "$key");
COMMIT;
EOF
    rm -f "$CONFIG_CACHE"
    ok "removed $key from scope '$scope' (a lower layer may still provide it)"
}

config_list() {  # [prefix]
    local prefix="${1:-}"
    printf '  %-38s %-24s %s\n' KEY VALUE FROM
    cat <<EOF | sq | while IFS="$SSMD_FS" read -r k v s; do
SELECT key, value, scope FROM (
  SELECT key, value, scope,
         ROW_NUMBER() OVER (PARTITION BY key ORDER BY
           CASE scope WHEN $(sq_quote "host:${SSMD_HOST:-local}") THEN 1
                      WHEN 'stack' THEN 2 WHEN 'default' THEN 3 ELSE 9 END) AS rank
    FROM config WHERE scope IN ($(sq_quote "host:${SSMD_HOST:-local}"), 'stack', 'default')
) WHERE rank = 1 $( [ -n "$prefix" ] && printf "AND key LIKE %s" "$(sq_quote "${prefix}%")" ) ORDER BY key;
EOF
        v="${v//\\n/, }"
        printf '  %-38s %-24s %s\n' "$k" "${v:0:24}" "$s"
    done
}

# Where a key's value comes from, and what the layers underneath say. The
# question this answers - "why is this value what it is" - is the one a layered
# configuration makes hard, so it gets a first-class command.
config_explain() {  # <key>
    local key="$1"
    [ -n "$key" ] || die "usage: ssmd config explain <key>"
    echo "  $key"
    echo
    printf '    %-16s %-30s %s\n' SCOPE VALUE ORIGIN
    cat <<EOF | sq | while IFS="$SSMD_FS" read -r s v o u; do
SELECT scope, value, origin, updated FROM config WHERE key = $(sq_quote "$key")
 ORDER BY CASE scope WHEN $(sq_quote "host:${SSMD_HOST:-local}") THEN 1
                     WHEN 'stack' THEN 2 WHEN 'default' THEN 3 ELSE 9 END;
EOF
        local mark=" "; [ "$s" = "host:${SSMD_HOST:-local}" ] && mark="*"
        # Other host scopes are shown because seeing them is how you notice a
        # value you set on the wrong machine profile; the star says which one
        # actually applies here.
        printf '  %s %-16s %-30s %s\n' "$mark" "$s" "${v:0:30}" "$o"
    done
    echo
    echo "    effective: $(config_get "$key" 2>/dev/null || echo '(unset)')   [host=${SSMD_HOST:-local}]"
    echo "    variable:  $(_config_varname "$key")"
}

config_history() {  # [key]
    local key="${1:-}"
    printf '  %-20s %-12s %-14s %-26s %s\n' WHEN ACTOR SCOPE KEY CHANGE
    cat <<EOF | sq | while IFS="$SSMD_FS" read -r ts actor scope k old new; do
SELECT ts, actor, scope, key, COALESCE(old_value,''), COALESCE(new_value,'')
  FROM config_history
 $( [ -n "$key" ] && printf "WHERE key = %s" "$(sq_quote "$key")" )
 ORDER BY id DESC LIMIT 40;
EOF
        # Three distinguishable cases. A bare value in this column used to mean
        # "first set in this scope", which reads identically to "changed to" and
        # sent people looking for a prior value that never existed.
        local change
        if   [ -z "$new" ]; then change="removed (was ${old:0:24})"
        elif [ -z "$old" ]; then change="set ${new:0:24}"
        else                     change="${old:0:16} -> ${new:0:24}"
        fi
        printf '  %-20s %-12s %-14s %-26s %s\n' "${ts:0:19}" "${actor:0:12}" "$scope" "${k:0:26}" "$change"
    done
}

# Write the database back out to the seed files, so a runtime `ssmd config set`
# can be committed. Only writes keys whose origin is 'set' back into the file -
# rewriting the whole file would strip every comment, and the comments in
# defaults.yml carry most of its value.
config_export() {
    local scope="${1:-stack}" n=0 key value
    local file
    case "$scope" in
        default) file=config/defaults.yml ;;
        stack)   file=config/stack.yml ;;
        host:*)  file=config/hosts.yml ;;
        *) die "usage: ssmd config export [stack|default|host:<name>]" ;;
    esac

    echo "  Keys changed at runtime in scope '$scope' and not yet in $file:"
    echo
    while IFS=$'\t' read -r key value; do
        [ -z "$key" ] && continue
        printf '    %-38s %s\n' "$key" "$value"
        n=$((n+1))
    done < <(printf "SELECT key, value FROM config WHERE scope=%s AND origin='set' ORDER BY key;" \
             "$(sq_quote "$scope")" | sq)

    if [ "$n" = 0 ]; then
        echo "    (none - the file and the database agree)"
        return 0
    fi
    echo
    hint "ssmd does not rewrite the seed files: doing so would strip the comments,"
    hint "which are most of what defaults.yml is for. Copy the lines above into"
    hint "$file by hand, then 'ssmd config import' to mark them as imported."
}

config_import_all() {
    log "importing all seeds"
    config_import_file config/defaults.yml default
    config_import_file config/stack.yml stack
    local h
    for h in $(config_host_scopes); do config_import_file config/hosts.yml "host:$h" 1; done
    rm -f "$CONFIG_CACHE"
    ok "imported $(printf 'SELECT COUNT(*) FROM config;' | sq1) keys across $(printf 'SELECT COUNT(DISTINCT scope) FROM config;' | sq1) scopes"
}

config_dispatch() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        get)      config_get "$@" ;;
        set)      config_set "$@" ;;
        unset)    config_unset "$@" ;;
        list|ls)  config_list "$@" ;;
        explain|why) config_explain "$@" ;;
        history|log) config_history "$@" ;;
        import)   config_import_all ;;
        export)   config_export "$@" ;;
        hosts)    echo "  available (SSMD_HOST in .env selects one):"
                  config_host_scopes | sed "s/^/    /;s/\$/$( [ -n "${SSMD_HOST:-}" ] && echo '' )/"
                  echo; echo "  active: ${SSMD_HOST:-local}" ;;
        path)     echo "$SSMD_DB_PATH" ;;
        *) cat <<'EOF'
ssmd config - configuration lives in SQLite, seeded from config/*.yml

  ssmd config list [prefix]        every effective value, and which layer it came from
  ssmd config get <key>            one effective value
  ssmd config set <key> <v> [scope]  change it now (scope: stack | default | host:<n>)
  ssmd config unset <key> [scope]
  ssmd config explain <key>        why this value - every layer, and the shell variable
  ssmd config history [key]        what changed, when, and who changed it
  ssmd config import               re-read config/*.yml into the database
  ssmd config export [scope]       runtime changes not yet written back to the seeds
  ssmd config hosts                host profiles available; SSMD_HOST selects one
  ssmd config path                 where the database is

Layers, highest first:  host:<SSMD_HOST>  >  stack  >  default
EOF
           ;;
    esac
}

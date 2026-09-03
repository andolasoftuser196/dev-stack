# lib/instance.sh - the machinery both `ssmd wt` and `ssmd agent` are built on.
#
# An instance is: a git worktree + its own database + its own Redis logical
# database + its own storage bucket + a route at <slug>.<domain>, all running as
# a separate compose project against the base stack's backing services.
#
# The registry lives in the same SQLite store as the configuration. It used to be
# a TSV file; moving it here bought three things that mattered:
#
#   - Real transactions. Allocating a Redis logical database and registering the
#     instance that owns it must be atomic, and with a file it was not: two
#     concurrent `ssmd wt add` calls could both read "3 is free".
#   - A UNIQUE constraint on redis_db, so the fifteen-instance ceiling is enforced
#     by the schema rather than by a comment and a loop.
#   - One place to look. The registry, the leases and the audit trail are all
#     answers to "what is going on", and three formats meant three ways to
#     disagree.

instances_count() { printf 'SELECT COUNT(*) FROM instances;' | sq1; }

instance_exists() {
    [ "$(printf 'SELECT COUNT(*) FROM instances WHERE slug=%s;' "$(sq_quote "$1")" | sq1)" != "0" ]
}

# Populates INSTANCE_* in the caller's shell. Every consumer of an instance goes
# through this rather than re-deriving names, so a naming change lands once.
# The one place that turns a slug into the INSTANCE_* variables every consumer
# reads. A heredoc, not printf: the SELECT contains SQL string literals ('') and
# nesting those inside a single-quoted printf format is how this function was
# silently broken for a while - it returned the format string itself.
instance_load() {
    local slug="$1" line
    line="$(cat <<EOF | sq1
SELECT slug, kind, COALESCE(branch,''), worktree, COALESCE(database,''),
       COALESCE(redis_db,0), created, COALESCE(owner,'')
  FROM instances WHERE slug = $(sq_quote "$slug");
EOF
)"
    [ -n "$line" ] || die "no such instance '$slug' (ssmd wt ls)"

    IFS="$SSMD_FS" read -r INSTANCE_SLUG INSTANCE_KIND INSTANCE_BRANCH INSTANCE_DIR \
                         INSTANCE_DB INSTANCE_REDIS_DB INSTANCE_CREATED INSTANCE_OWNER <<< "$line"
    export INSTANCE_SLUG INSTANCE_KIND INSTANCE_BRANCH INSTANCE_DIR \
           INSTANCE_DB INSTANCE_REDIS_DB INSTANCE_CREATED INSTANCE_OWNER

    # This instance's own DATABASE_URL. Same shape as the base stack's, pointed
    # at this instance's database.
    case "$DB_ENGINE" in
        mysql|postgres)
            export INSTANCE_DATABASE_URL="${DATABASE_URL%/*}/${INSTANCE_DB}" ;;
        *)  export INSTANCE_DATABASE_URL="" ;;
    esac
}

instance_register() {
    printf 'INSERT INTO instances(slug,kind,branch,worktree,database,redis_db,created,owner) VALUES(%s,%s,%s,%s,%s,%s,%s,%s);' \
        "$(sq_quote "$1")" "$(sq_quote "$2")" "$(sq_quote "$3")" "$(sq_quote "$4")" \
        "$(sq_quote "$5")" "$6" "$(sq_quote "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
        "$(sq_quote "${7:-${USER:-unknown}}")" | sq >/dev/null \
        || die "could not register instance '$1' - is the slug or redis database already taken? (ssmd wt ls)"
    audit "instance.register" "$2/$1 branch=$3 db=$5 redis=$6"
}

instance_unregister() {
    # Leases cascade (ON DELETE CASCADE), so a removed instance cannot leave one
    # behind to be reaped forever.
    printf 'DELETE FROM instances WHERE slug=%s;' "$(sq_quote "$1")" | sq >/dev/null
    audit "instance.unregister" "$1"
}

# Redis has 16 logical databases and 0 belongs to the base stack, so 1-15 are the
# instance pool. That ceiling - not memory, not ports - is the real reason
# max_concurrent exists, and it is worth knowing before you plan for twenty
# branches at once.
# Redis logical databases: 0 belongs to the base stack, the rest are the pool.
# That range - not memory, not ports - is the real concurrency ceiling.
#
# The lowest free number, found in SQL. A UNIQUE constraint on the column is what
# actually prevents a double allocation; this query only picks a candidate.
instance_alloc_redis_db() {
    local lo hi n
    lo="$(_cfg INSTANCES_REDIS_DB_MIN)"; hi="$(_cfg INSTANCES_REDIS_DB_MAX)"
    n="$(cat <<EOF | sq1
WITH RECURSIVE pool(n) AS (
  SELECT $lo UNION ALL SELECT n+1 FROM pool WHERE n < $hi
)
SELECT n FROM pool WHERE n NOT IN (SELECT COALESCE(redis_db,-1) FROM instances) LIMIT 1;
EOF
)"
    [ -n "$n" ] || die "all Redis logical databases ${lo}-${hi} are allocated.
      That is the concurrency ceiling. Free one: ssmd wt ls, then ssmd wt rm <slug>
      (or raise it, if your Redis has more: ssmd config set instances.redis_db_max N)"
    echo "$n"
}

instance_db_name() { echo "${DB_NAME}_$(echo "$1" | tr '-' '_')"; }

# Slugs become hostnames, database names and container names, so the reserved
# list is not cosmetic: an instance called "app" would shadow the main stack's
# own route and silently take its traffic.
instance_slug_for_branch() {
    local slug; slug="$(slugify "$1")"
    [ -n "$slug" ] || die "branch '$1' does not reduce to a usable slug"
    case " $(_cfg INSTANCES_RESERVED) " in
        *" $slug "*) die "slug '$slug' is reserved - it collides with a stack route.
      Choose another with --slug." ;;
    esac
    echo "$slug"
}

# ── proxy routes ────────────────────────────────────────────────────────────
instance_write_route() {
    local slug="$1" upstream="$2"
    cat > "caddy/proxy/sites/${slug}.caddy" <<EOF
# Generated by ssmd for instance '${slug}'. Removed on teardown.
# Do not edit: the next 'ssmd ${INSTANCE_KIND:-wt} up ${slug}' overwrites it.
http://${slug}.${STACK_DOMAIN}, https://${slug}.${STACK_DOMAIN} {
	reverse_proxy ${upstream} {
		flush_interval -1
		header_up X-Ssmd-Instance ${slug}
	}
}
EOF
    instance_reload_proxy
}

instance_remove_route() {
    rm -f "caddy/proxy/sites/${1}.caddy"
    instance_reload_proxy
}

# Reload, never restart. A restart drops every in-flight request across every
# instance; a reload is atomic and keeps them. The `|| warn` matters too: a
# Caddyfile syntax error must not leave the caller thinking the route is live.
instance_reload_proxy() {
    container_running proxy || return 0
    if docker exec "$(container proxy)" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        return 0
    fi
    warn "proxy reload failed - the route is written but not live.
       Check the config:  ssmd exec proxy caddy validate --config /etc/caddy/Caddyfile"
    return 1
}

# ── /etc/hosts ──────────────────────────────────────────────────────────────
# /etc/hosts cannot express a wildcard, so without wildcard DNS every instance
# needs its own line. Writing it requires root, which ssmd will not take silently:
# it prints the line unless MANAGE_ETC_HOSTS=1 says otherwise.
instance_hosts_add() {
    local host="$1.$STACK_DOMAIN"
    getent hosts "$host" >/dev/null 2>&1 && return 0
    if [ "${MANAGE_ETC_HOSTS:-0}" = "1" ]; then
        if printf '127.0.0.1 %s\n' "$host" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
            ok "added $host to /etc/hosts"; return 0
        fi
        warn "could not write /etc/hosts (needs passwordless sudo)"
    fi
    hint "add this line to the hosts file of whatever you browse from:"
    hint "    127.0.0.1 $host"
}

instance_hosts_rm() {
    local host="$1.$STACK_DOMAIN"
    [ "${MANAGE_ETC_HOSTS:-0}" = "1" ] || return 0
    sudo sed -i.ssmdbak "/[[:space:]]${host}\$/d" /etc/hosts 2>/dev/null || true
}

# ── compose for one instance ────────────────────────────────────────────────
instance_compose() {
    instance_load "$INSTANCE_SLUG_ARG"
    docker compose \
        -p "${PROJECT}-${INSTANCE_KIND}-${INSTANCE_SLUG}" \
        -f docker-compose.instance.yml "$@"
}

# ── worktree creation ───────────────────────────────────────────────────────
instance_create_worktree() {  # <branch> <path> [base]
    local branch="$1" path="$2" base="${3:-}"
    [ -d "$path" ] && { log "worktree already present at $path"; return 0; }
    mkdir -p "$(dirname "$path")"

    if git -C "$GIT_ROOT" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
        log "worktree from existing branch '$branch'"
        git -C "$GIT_ROOT" worktree add "$path" "$branch"
    else
        # Default the base to the repo's current HEAD rather than to a hardcoded
        # "main": a monorepo's default branch is not always main, and branching a
        # feature off the wrong base wastes the whole run before anyone notices.
        base="${base:-$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD)}"
        log "worktree from new branch '$branch' off '$base'"
        git -C "$GIT_ROOT" worktree add -b "$branch" "$path" "$base"
    fi

    # Files git does not track but the app needs to run. Copied, not symlinked:
    # a symlinked .env means editing the instance's config edits the main
    # checkout's, which defeats the isolation people came for.
    local f
    for f in .env .env.local; do
        [ -f "$GIT_ROOT/$f" ] && [ ! -f "$path/$f" ] && cp "$GIT_ROOT/$f" "$path/$f"
    done
    return 0
}

instance_remove_worktree() {  # <path> <branch> [--delete-branch]
    local path="$1" branch="$2" del="${3:-}"
    [ -d "$path" ] || return 0
    git -C "$GIT_ROOT" worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
    git -C "$GIT_ROOT" worktree prune
    if [ "$del" = "--delete-branch" ] && [ -n "$branch" ]; then
        # -d, never -D. A branch with unmerged commits is exactly the branch you
        # do not want deleted by a cleanup command, and git already knows how to
        # tell the difference.
        git -C "$GIT_ROOT" branch -d "$branch" 2>/dev/null \
            || warn "branch '$branch' has unmerged commits - left in place.
       Delete it deliberately with: git -C $GIT_ROOT branch -D $branch"
    fi
}

# ── leases ──────────────────────────────────────────────────────────────────
# A lease answers "who owns this instance and until when". Without one, an agent
# that crashed holds a slot forever, and the slot count is a hard limit.
lease_write() {  # <slug> <owner> <ttl e.g. 4h>
    local slug="$1" owner="$2" ttl="${3:-4h}" secs now
    case "$ttl" in
        *h) secs=$(( ${ttl%h} * 3600 )) ;;
        *m) secs=$(( ${ttl%m} * 60 )) ;;
        *d) secs=$(( ${ttl%d} * 86400 )) ;;
        *)  secs="$ttl" ;;
    esac
    now="$(date -u +%s)"
    printf 'INSERT OR REPLACE INTO leases(slug,owner,acquired,expires,ttl) VALUES(%s,%s,%s,%s,%s);' \
        "$(sq_quote "$slug")" "$(sq_quote "$owner")" "$now" "$(( now + secs ))" "$(sq_quote "$ttl")" \
        | sq >/dev/null
}

_lease_expires() {
    printf 'SELECT expires FROM leases WHERE slug=%s;' "$(sq_quote "$1")" | sq1
}

lease_expired() {
    local e; e="$(_lease_expires "$1")"
    [ -z "$e" ] && return 0
    [ "$(date -u +%s)" -gt "$e" ]
}

lease_owner() {
    local o; o="$(printf 'SELECT owner FROM leases WHERE slug=%s;' "$(sq_quote "$1")" | sq1)"
    printf '%s' "${o:--}"
}

lease_remaining() {
    local e now; e="$(_lease_expires "$1")"; now="$(date -u +%s)"
    [ -z "$e" ] && { echo "-"; return; }
    if [ "$now" -gt "$e" ]; then echo "expired"
    else printf '%dm\n' $(( (e - now) / 60 )); fi
}

lease_remove() { printf 'DELETE FROM leases WHERE slug=%s;' "$(sq_quote "$1")" | sq >/dev/null; }

# ── listing ─────────────────────────────────────────────────────────────────
instances_list() {  # [kind]
    local want="${1:-}"
    if [ "$(instances_count)" = "0" ]; then
        echo "  no instances. Create one:  ssmd wt add <branch>"
        return 0
    fi
    printf '  %-24s %-6s %-26s %-9s %-6s %-8s %s\n' SLUG KIND BRANCH STATE REDIS LEASE URL
    while IFS="$SSMD_FS" read -r slug kind branch dir dbname rdb created owner; do
        [ -z "${slug:-}" ] && continue
        [ -n "$want" ] && [ "$kind" != "$want" ] && continue
        local state=stopped cname="${PROJECT}-${kind}-${slug}-app"
        docker ps --format '{{.Names}}' | grep -qx "$cname" && state=running
        [ -d "$dir" ] || state=NO-TREE
        local port=""; [ "${PROXY_HTTPS_PORT:-443}" != "443" ] && port=":${PROXY_HTTPS_PORT}"
        printf '  %-24s %-6s %-26s %-9s %-6s %-8s https://%s.%s%s/\n' \
            "$slug" "$kind" "${branch:0:26}" "$state" "$rdb" "$(lease_remaining "$slug")" \
            "$slug" "$STACK_DOMAIN" "$port"
    done < <(cat <<'EOF' | sq
SELECT slug, kind, COALESCE(branch,''), worktree, COALESCE(database,''),
       COALESCE(redis_db,0), created, COALESCE(owner,'')
  FROM instances ORDER BY created;
EOF
)
}

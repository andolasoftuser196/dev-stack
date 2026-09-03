# lib/worktree.sh - `dx wt`: run several branches at once.
#
# Each instance is a full environment at https://<slug>.<domain> with its own
# checkout, database, Redis logical database and bucket, sharing the base
# stack's one database server, cache, mail catcher and object store.
#
# Sharing the backends is the whole trick. Per-branch stacks that each run their
# own MySQL are what people build first, and they stop being usable at three
# concurrent branches because the memory is gone.

wt_usage() {
    cat <<'EOF'
dx wt - run several branches concurrently

  dx wt add <branch> [--slug s] [--base b] [--no-queue] [--from-snapshot f] [--empty-db]
  dx wt ls
  dx wt up <slug>            start an instance that exists but is stopped
  dx wt stop <slug>
  dx wt rm <slug> [--drop-db] [--delete-branch]
  dx wt logs <slug> [service] [-f]
  dx wt sh <slug>
  dx wt exec <slug> <cmd...>
  dx wt verify <slug>

Each instance gets:
  https://<slug>.<domain>    own route through the proxy
  <db>_<slug>                own database (snapshot-provisioned by default)
  own redis logical db       and key prefix (the pool is a config range)
  bucket <slug>              own object storage bucket
EOF
}

wt_add() {
    local branch="" slug="" base="" want_queue=1 from_snapshot="" seed=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) slug="${2:?}"; shift 2 ;;
            --base) base="${2:?}"; shift 2 ;;
            --no-queue) want_queue=0; shift ;;
            --from-snapshot) from_snapshot="${2:?}"; shift 2 ;;
            --empty-db) seed=0; shift ;;
            -*) die "unknown flag '$1' (dx wt add --help)" ;;
            *) [ -z "$branch" ] && { branch="$1"; shift; } || die "unexpected argument '$1'" ;;
        esac
    done
    [ -n "$branch" ] || { wt_usage; exit 1; }

    _instance_add "wt" "$branch" "$slug" "$base" "$want_queue" "$from_snapshot" "$seed" "${USER:-unknown}"
}

# Shared by `dx wt add` and `dx agent spawn`. The only differences an agent
# instance introduces are the sandbox container, the lease and the egress
# policy - everything below is identical, and keeping it identical is what stops
# the two paths from drifting apart.
_instance_add() {
    local kind="$1" branch="$2" slug="$3" base="$4" want_queue="$5" \
          from_snapshot="$6" seed="$7" owner="$8"

    [ -d "$GIT_ROOT/.git" ] || git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
        || die "no git repository at $GIT_ROOT - instances need one"

    container_running proxy || die "the base stack is not running. Start it first: dx up"

    slug="${slug:-$(instance_slug_for_branch "$branch")}"
    instance_exists "$slug" && die "instance '$slug' already exists (dx wt ls)"

    local n; n="$(instances_count)"
    if [ "$n" -ge "$STACK_AGENTS_MAX_CONCURRENT" ] && [ "$kind" = "agent" ]; then
        die "already at agents.max_concurrent=${STACK_AGENTS_MAX_CONCURRENT}.
      Free a slot: dx agent ls, then dx agent rm <slug>"
    fi

    local dir="$WORKTREE_ROOT/$slug"
    local dbname; dbname="$(instance_db_name "$slug")"
    local rdb;    rdb="$(instance_alloc_redis_db)"

    log "creating $kind instance '$slug'"
    hint "branch=$branch  db=$dbname  redis=$rdb  dir=$dir"

    instance_create_worktree "$branch" "$dir" "$base"

    # Provision the database. Restoring a snapshot is the fast path and the
    # default when one exists: migrating from empty on a mature schema takes
    # minutes, and a two-minute wait is enough to stop people creating instances.
    if [ "$DB_ENGINE" != none ]; then
        db_create_database "$dbname"
        if [ -n "$from_snapshot" ]; then
            db_restore "$from_snapshot" "$dbname"
        elif [ "$seed" = 1 ] && [ "$(_cfg INSTANCES_SEED_FROM_SNAPSHOT)" = "true" ]; then
            local latest
            latest="$(ls -t data/snapshots/*.sql.gz 2>/dev/null | head -n1 || true)"
            if [ -n "$latest" ]; then
                log "seeding from the most recent snapshot: $latest"
                hint "use --empty-db to skip, or --from-snapshot <file> to pick another"
                db_restore "$latest" "$dbname"
            else
                log "no snapshot to seed from - the instance starts with an empty database"
                hint "after it boots:  dx wt exec $slug <your migrate command>"
            fi
        fi
    fi

    # Storage bucket. Best-effort: a project with services.storage: none has no
    # minio container and should not fail instance creation over it.
    if container_running minio; then
        docker exec "$(container minio)" sh -c \
            "mc alias set local http://127.0.0.1:${PORT_MINIO_S3} '${S3_KEY}' '${S3_SECRET}' >/dev/null 2>&1 && \
             mc mb --ignore-existing local/${slug} >/dev/null 2>&1" || true
    fi

    instance_register "$slug" "$kind" "$branch" "$dir" "$dbname" "$rdb" "$owner"

    INSTANCE_SLUG_ARG="$slug"
    _instance_up "$slug" "$want_queue" "$( [ "$kind" = agent ] && echo 1 || echo 0 )"

    instance_hosts_add "$slug"

    echo
    ok "$kind instance '$slug' is up"
    echo "     https://${slug}.${STACK_DOMAIN}/"
    echo "     dx wt logs $slug -f       dx wt sh $slug       dx wt verify $slug"
}

_instance_up() {  # <slug> <want_queue> <want_sandbox>
    local slug="$1" want_queue="$2" want_sandbox="$3"
    INSTANCE_SLUG_ARG="$slug"
    instance_load "$slug"

    local pargs=()
    [ "$want_queue" = 1 ] && [ "${STACK_SERVICES_QUEUE}" = "true" ] && pargs+=(--profile queue)
    [ "$want_sandbox" = 1 ] && pargs+=(--profile sandbox)

    export AGENT_PROXY=""
    if [ "$want_sandbox" = 1 ] && [ "${STACK_AGENTS_EGRESS}" = "allowlist" ]; then
        export AGENT_PROXY="http://egress:${PORT_EGRESS}"
    fi

    log "starting containers"
    docker compose -p "${PROJECT}-${INSTANCE_KIND}-${slug}" \
        -f docker-compose.instance.yml "${pargs[@]}" up -d

    instance_write_route "$slug" "${PROJECT}-${INSTANCE_KIND}-${slug}-app:${STACK_RUNTIME_PORT}"

    # Dependencies, then the per-instance lifecycle hook. Skipping the install
    # when the tree already has them is what makes a second instance on the same
    # branch fast.
    log "installing dependencies (shared cache at data/build-cache)"
    _instance_exec "$slug" "true" >/dev/null 2>&1 || sleep 3
    if ! _rt_in_instance "$slug" rt_deps_present; then
        _instance_run_deps "$slug"
    else
        ok "dependencies already present"
    fi

    _instance_run_hooks "$slug" "$STACK_HOOKS_POSTINSTANCE"
}

# Through the runtime, for the same reason `dx run` is: a project command needs
# the environment the entrypoint set up, and docker exec does not run it.
_instance_exec() {  # <slug> <cmd...>
    local slug="$1"; shift
    instance_load "$slug"
    local saved; saved="$(declare -f container)"
    container() { echo "${PROJECT}-${INSTANCE_KIND}-${slug}-$1"; }
    local rc=0; rt_exec app "$*" || rc=$?
    eval "$saved"
    return $rc
}

# Dependency install inside an instance. The runtime module knows the command;
# it just needs to run in the instance's container rather than the main app's.
_instance_run_deps() {
    local slug="$1"
    instance_load "$slug"
    local saved_container_fn; saved_container_fn="$(declare -f container)"
    # Temporarily point container() at this instance so the runtime's rt_*
    # functions operate on it without needing an instance-aware variant of each.
    container() { echo "${PROJECT}-${INSTANCE_KIND}-${slug}-$1"; }
    rt_deps_install || warn "dependency install failed - the app may not boot"
    eval "$saved_container_fn"
}

_rt_in_instance() {
    local slug="$1" fn="$2"
    instance_load "$slug"
    local saved; saved="$(declare -f container)"
    container() { echo "${PROJECT}-${INSTANCE_KIND}-${slug}-$1"; }
    local rc=0; "$fn" || rc=$?
    eval "$saved"
    return $rc
}

_instance_run_hooks() {
    local slug="$1" hooks="$2" h
    [ -z "$hooks" ] && return 0
    # Array first: _instance_exec runs docker exec, which would otherwise read
    # the remaining hooks off stdin. Same bug, same shape, as run_hooks in dx.
    local list=(); mapfile -t list <<< "$hooks"
    for h in "${list[@]}"; do
        [ -z "$h" ] && continue
        log "hook: $h"
        _instance_exec "$slug" "$h" || warn "hook failed: $h"
    done
}

wt_rm() {
    local slug="" drop_db=0 del_branch=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --drop-db) drop_db=1; shift ;;
            --delete-branch) del_branch=1; shift ;;
            -*) die "unknown flag '$1'" ;;
            *) slug="$1"; shift ;;
        esac
    done
    [ -n "$slug" ] || die "usage: dx wt rm <slug> [--drop-db] [--delete-branch]"
    instance_load "$slug"

    log "removing $INSTANCE_KIND instance '$slug'"

    docker compose -p "${PROJECT}-${INSTANCE_KIND}-${slug}" \
        -f docker-compose.instance.yml --profile queue --profile sandbox down -v --remove-orphans 2>/dev/null || true

    instance_remove_route "$slug"
    instance_hosts_rm "$slug"

    if [ "$drop_db" = 1 ] && [ "$DB_ENGINE" != none ]; then
        # db_drop_database snapshots first and refuses if the snapshot fails, so
        # there is always a way back from this.
        db_drop_database "$INSTANCE_DB"
    else
        [ "$DB_ENGINE" != none ] && \
            hint "database '$INSTANCE_DB' kept. Remove it with: dx db:drop $INSTANCE_DB"
    fi

    if [ "$del_branch" = 1 ]; then
        instance_remove_worktree "$INSTANCE_DIR" "$INSTANCE_BRANCH" --delete-branch
    else
        instance_remove_worktree "$INSTANCE_DIR" "$INSTANCE_BRANCH"
    fi

    lease_remove "$slug"
    instance_unregister "$slug"
    ok "removed '$slug'"
}

wt_dispatch() {
    local sub="${1:-ls}"; shift || true
    case "$sub" in
        add)      wt_add "$@" ;;
        ls|list)  instances_list wt ;;
        up)       [ $# -ge 1 ] || die "usage: dx wt up <slug>"
                  _instance_up "$1" 1 0; instance_write_route "$1" "${PROJECT}-wt-${1}-app:${STACK_RUNTIME_PORT}" ;;
        stop)     [ $# -ge 1 ] || die "usage: dx wt stop <slug>"
                  instance_load "$1"
                  docker compose -p "${PROJECT}-${INSTANCE_KIND}-${1}" -f docker-compose.instance.yml \
                      --profile queue --profile sandbox stop ;;
        rm|remove) wt_rm "$@" ;;
        logs)     [ $# -ge 1 ] || die "usage: dx wt logs <slug> [service] [-f]"
                  local s="$1"; shift; instance_load "$s"
                  docker compose -p "${PROJECT}-${INSTANCE_KIND}-${s}" -f docker-compose.instance.yml \
                      --profile queue --profile sandbox logs --tail 200 "$@" ;;
        sh|shell) [ $# -ge 1 ] || die "usage: dx wt sh <slug>"
                  instance_load "$1"
                  dexec "${PROJECT}-${INSTANCE_KIND}-${1}-app" sh -l ;;
        exec)     [ $# -ge 2 ] || die "usage: dx wt exec <slug> <cmd...>"
                  local s="$1"; shift; _instance_exec "$s" "$*" ;;
        verify)   [ $# -ge 1 ] || die "usage: dx wt verify <slug>"; cmd_verify "$1" ;;
        help|-h|--help) wt_usage ;;
        *) wt_usage; die "unknown subcommand 'wt $sub'" ;;
    esac
}

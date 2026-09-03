# lib/agent.sh - `ssmd agent`: give a coding agent its own isolated environment.
#
# An agent sandbox is a worktree instance plus three things:
#
#   1. a container the agent runs *inside*, on the isolated network, with the
#      worktree as the only writable path into the repo;
#   2. a lease, so a crashed agent does not hold a slot forever;
#   3. a policy verdict on whatever it changed, before that change goes anywhere.
#
# The shape is the one that survives contact with real use: a disposable
# container per run, resource caps that fail loudly rather than swapping, an
# allowlist of paths a change may not touch, and size caps that stand in for "a
# human can review this in one sitting". The verdict never blocks the work - it
# blocks the work from landing unattended. That distinction is the whole reason
# people keep it switched on.

agent_usage() {
    cat <<'EOF'
ssmd agent - isolated environments for coding agents

  ssmd agent spawn <branch> [--slug s] [--owner who] [--ttl 4h] [--egress none|allowlist|full]
  ssmd agent ls
  ssmd agent up <slug> | stop <slug>    restart or stop an existing sandbox
  ssmd agent attach <slug>              shell inside the sandbox (where the agent runs)
  ssmd agent run <slug> <cmd...>        run one command inside the sandbox
  ssmd agent logs <slug> [-f]
  ssmd agent verify <slug>              did the agent's change actually work?
  ssmd agent diff <slug>                what changed, plus the policy verdict
  ssmd agent rm <slug> [--drop-db] [--delete-branch]
  ssmd agent reap                       remove sandboxes whose lease has expired
  ssmd agent policy                     show the active policy
  ssmd agent audit [-n 50] [--actor who] [--event kind]
                                      what agents have actually done

Isolation (see docs/AGENTS.md):
  network    isolated only; egress via an allowlist proxy, or none at all
  filesystem the worktree is writable; the main checkout is not mounted
  resources  cpus/memory/pids capped per stack.yml agents.*
  policy     denied paths + size caps evaluated by 'ssmd agent diff'
EOF
}

agent_spawn() {
    local branch="" slug="" owner="${SSMD_ACTOR:-${USER:-agent}}" \
          ttl="$STACK_AGENTS_LEASE_TTL" egress="$STACK_AGENTS_EGRESS" \
          from_snapshot="" want_queue=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)  slug="${2:?}"; shift 2 ;;
            --owner) owner="${2:?}"; shift 2 ;;
            --ttl)   ttl="${2:?}"; shift 2 ;;
            --egress) egress="${2:?}"; shift 2 ;;
            --from-snapshot) from_snapshot="${2:?}"; shift 2 ;;
            --no-queue) want_queue=0; shift ;;
            -*) die "unknown flag '$1' (ssmd agent spawn --help)" ;;
            *) [ -z "$branch" ] && { branch="$1"; shift; } || die "unexpected argument '$1'" ;;
        esac
    done
    [ -n "$branch" ] || { agent_usage; exit 1; }

    case "$egress" in
        none|allowlist|full) ;;
        *) die "--egress must be none, allowlist or full" ;;
    esac
    if [ "$egress" = "full" ]; then
        warn "egress=full: this sandbox reaches the whole internet."
        hint "That is a development convenience, not a posture for an unattended run."
    fi

    # The egress proxy is a base-stack service; start it before the sandbox that
    # depends on it, or the sandbox comes up with a proxy address that resolves
    # to nothing and every outbound call hangs until its timeout.
    if [ "$egress" = "allowlist" ]; then
        container_running egress || {
            log "starting the egress allowlist proxy"
            compose --profile egress up -d egress
        }
    fi

    export STACK_AGENTS_EGRESS="$egress"
    _instance_add "agent" "$branch" "$slug" "" "$want_queue" "$from_snapshot" 1 "$owner"

    slug="${slug:-$(instance_slug_for_branch "$branch")}"
    lease_write "$slug" "$owner" "$ttl"
    audit "agent.spawn" "slug=$slug branch=$branch owner=$owner ttl=$ttl egress=$egress"

    cat <<EOF

  Sandbox '$slug' ready.

    attach     ssmd agent attach $slug
    app        https://${slug}.${STACK_DOMAIN}/
    lease      $owner, expires in $(lease_remaining "$slug")
    egress     $egress$( [ "$egress" = allowlist ] && echo " (policy/allow-hosts.txt)" )

  From inside the sandbox: the worktree at /app, ssmd read-only at /ssmd, this
  instance's app at \$SSMD_APP_URL (address it by that or by '${slug}' - never by
  'app', which resolves round-robin across every instance), and no route off this
  box except the allowlist.
EOF
}

agent_attach() {
    local slug="${1:?usage: ssmd agent attach <slug>}"
    instance_load "$slug"
    [ "$INSTANCE_KIND" = "agent" ] || die "'$slug' is a $INSTANCE_KIND instance, not an agent sandbox"
    local c="${PROJECT}-agent-${slug}-sandbox"
    docker ps --format '{{.Names}}' | grep -qx "$c" || die "sandbox container '$c' is not running (ssmd agent ls)"
    audit "agent.attach" "$slug"
    dexec "$c" bash -l
}

agent_run() {
    local slug="${1:?usage: ssmd agent run <slug> <cmd...>}"; shift
    instance_load "$slug"
    audit "agent.run" "$slug: $*"
    dexec "${PROJECT}-agent-${slug}-sandbox" bash -c "$*"
}

# ── the policy verdict ──────────────────────────────────────────────────────
# Reads policy/policy.yml, evaluates the instance's working tree against it, and
# says what would and would not be safe to land unattended.
#
# It does not stop anything. A change touching a denied path is still a
# perfectly good change; it just needs a human to look at it. A gate that
# refused to produce the work would throw away correct fixes for touching a
# migration, which is the opposite of useful.
agent_diff() {
    local slug="${1:?usage: ssmd agent diff <slug>}"
    instance_load "$slug"

    local files lines
    # -uall, not the default. `git status --porcelain` collapses an untracked
    # directory to a single "database/" entry, so a brand-new migration inside a
    # brand-new directory is never matched against the policy - the gate silently
    # passes exactly the change it exists to hold.
    #
    # The sed strips the two status columns and the following space; the second
    # expression takes the destination side of a rename ("R  old -> new"), which
    # is the path the policy should judge.
    files="$(git -C "$INSTANCE_DIR" status --porcelain -uall 2>/dev/null \
             | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"\(.*\)"$/\1/')"
    if [ -z "$files" ]; then
        echo "  no uncommitted changes in $INSTANCE_DIR"
        # Fall back to the diff against the base, which is what matters once the
        # agent has committed - the common case by the time anyone asks.
        files="$(git -C "$INSTANCE_DIR" diff --name-only "$(_agent_merge_base "$slug")"...HEAD 2>/dev/null)"
        lines="$(git -C "$INSTANCE_DIR" diff --shortstat "$(_agent_merge_base "$slug")"...HEAD 2>/dev/null \
                 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)"
        [ -z "$files" ] && { echo "  and nothing committed on this branch either"; return 0; }
        echo "  showing committed changes on '$INSTANCE_BRANCH' instead"
    else
        lines="$(git -C "$INSTANCE_DIR" diff --shortstat 2>/dev/null \
                 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)"
    fi

    local nfiles; nfiles="$(printf '%s\n' "$files" | grep -c . || echo 0)"
    echo
    echo "  Changed: ${nfiles} file(s), ~${lines:-0} line(s)"
    printf '%s\n' "$files" | sed 's/^/    /'

    echo
    policy_evaluate "$files" "$nfiles" "${lines:-0}"
}

_agent_merge_base() {
    instance_load "$1"
    git -C "$INSTANCE_DIR" merge-base HEAD "$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD)" 2>/dev/null \
        || echo "HEAD~1"
}

# ── reaping ─────────────────────────────────────────────────────────────────
# A strictly serial runner can sweep orphans at startup, because at startup
# nothing legitimate can exist. Several sandboxes at once removes that guarantee,
# so the lease is what distinguishes debris from live work - and reaping is an
# explicit command rather than something `ssmd up` does behind your back.
agent_reap() {
    local reaped=0 slug
    [ "$(instances_count)" != "0" ] || { echo "  nothing to reap"; return 0; }
    # Fetched into an array first - wt_rm below reads stdin (docker exec, and
    # confirm()), which would otherwise be this result set.
    local rows=(); mapfile -t rows < <(printf "SELECT slug,kind,'','','','','',COALESCE(owner,'') FROM instances;" | sq)
    local row kind owner
    for row in "${rows[@]}"; do
        [ -z "$row" ] && continue
        IFS="$SSMD_FS" read -r slug kind _b _d _db _r _c owner <<< "$row"
        [ "$kind" = "agent" ] || continue
        lease_expired "$slug" || continue
        warn "lease for '$slug' (owner $owner) expired"
        if confirm "  remove sandbox '$slug' and its worktree?"; then
            wt_rm "$slug"
            reaped=$((reaped+1))
        fi
    done
    [ "$reaped" = 0 ] && echo "  no expired sandboxes" || ok "reaped $reaped"
}

# The audit trail. A table now rather than a JSONL file, which means it can be
# filtered and counted rather than only tailed - `what did the agent do between
# 3pm and 4pm` is a WHERE clause instead of a careful grep.
agent_audit() {
    local n=50 who="" ev=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n)      n="${2:-50}"; shift 2 ;;
            --actor) who="${2:?}"; shift 2 ;;
            --event) ev="${2:?}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local where="1=1"
    [ -n "$who" ] && where="$where AND actor LIKE $(sq_quote "%${who}%")"
    [ -n "$ev" ]  && where="$where AND event LIKE $(sq_quote "%${ev}%")"

    local found=0
    printf '  %-20s %-14s %-22s %s\n' WHEN ACTOR EVENT DETAIL
    while IFS="$SSMD_FS" read -r ts actor event detail; do
        [ -z "$ts" ] && continue
        found=1
        printf '  %-20s %-14s %-22s %s\n' "${ts:0:19}" "${actor:0:14}" "${event:0:22}" "${detail:0:60}"
    done < <(printf "SELECT ts, actor, event, COALESCE(detail,'') FROM audit WHERE %s ORDER BY id DESC LIMIT %d;" \
             "$where" "$n" | sq)
    [ "$found" = 0 ] && echo "  (no matching entries)"
    return 0
}

agent_dispatch() {
    local sub="${1:-ls}"; shift || true
    case "$sub" in
        spawn|add)  agent_spawn "$@" ;;
        ls|list)    instances_list agent ;;
        # `ssmd wt up` deliberately never starts a sandbox, so restarting a stopped
        # agent instance needs its own verb rather than a flag on the other one.
        up|start)   [ $# -ge 1 ] || die "usage: ssmd agent up <slug>"
                    instance_load "$1"
                    [ "$INSTANCE_KIND" = agent ] || die "'$1' is a $INSTANCE_KIND instance - use 'ssmd wt up $1'"
                    if [ "${STACK_AGENTS_EGRESS}" = "allowlist" ]; then
                        container_running egress || compose --profile egress up -d egress
                    fi
                    _instance_up "$1" 1 1
                    instance_write_route "$1" "${PROJECT}-agent-${1}-app:${STACK_RUNTIME_PORT}"
                    ok "sandbox '$1' is up - ssmd agent attach $1" ;;
        stop)       [ $# -ge 1 ] || die "usage: ssmd agent stop <slug>"
                    instance_load "$1"
                    docker compose -p "${PROJECT}-agent-${1}" -f docker-compose.instance.yml \
                        --profile queue --profile sandbox stop ;;
        attach|sh)  agent_attach "$@" ;;
        run|exec)   agent_run "$@" ;;
        logs)       [ $# -ge 1 ] || die "usage: ssmd agent logs <slug> [-f]"
                    local s="$1"; shift; instance_load "$s"
                    docker compose -p "${PROJECT}-agent-${s}" -f docker-compose.instance.yml \
                        --profile sandbox --profile queue logs --tail 200 "$@" ;;
        verify)     [ $# -ge 1 ] || die "usage: ssmd agent verify <slug>"; cmd_verify "$1" ;;
        diff)       agent_diff "$@" ;;
        rm|remove)  wt_rm "$@" ;;
        reap)       agent_reap ;;
        policy)     policy_show ;;
        audit)      agent_audit "$@" ;;
        help|-h|--help) agent_usage ;;
        *) agent_usage; die "unknown subcommand 'agent $sub'" ;;
    esac
}

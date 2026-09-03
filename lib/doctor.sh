# lib/doctor.sh - preflight, drift detection, end-to-end verification, status.
#
# Three read-only commands that answer three different questions:
#
#   ssmd preflight   "will `ssmd up` work on this machine?"      - host, before start
#   ssmd doctor      "does reality match what ssmd thinks?"      - drift, any time
#   ssmd verify      "is the app actually working right now?"  - behaviour, after start
#
# Keeping them separate matters. Merging them produces a command that is too slow
# to run casually and too vague to act on, and the first thing anyone does with
# such a command is stop running it.
#
# All three are read-only and all three exit non-zero on failure, so they compose
# into CI and into an agent's decision to stop and ask.

_pf_fails=0; _pf_warns=0
_pf_ok()   { ok   "$1"; }
_pf_warn() { warn "$1"; _pf_warns=$((_pf_warns+1)); }
_pf_fail() { fail "$1"; _pf_fails=$((_pf_fails+1)); }

# ── preflight ───────────────────────────────────────────────────────────────
cmd_preflight() {
    _pf_fails=0; _pf_warns=0
    echo "Preflight - $(uname -s) $(uname -m), stack '${STACK_NAME}' at ${STACK_DOMAIN}"
    echo

    if command -v docker >/dev/null 2>&1; then
        _pf_ok "docker present ($(docker --version | sed 's/,.*//'))"
        docker info >/dev/null 2>&1 && _pf_ok "docker daemon reachable" \
            || _pf_fail "docker daemon not reachable - is it running, and are you in the docker group?"
        docker compose version >/dev/null 2>&1 \
            && _pf_ok "docker compose v2 ($(docker compose version --short))" \
            || _pf_fail "docker compose v2 plugin missing (the standalone docker-compose v1 will not work)"
    else
        _pf_fail "docker CLI missing"
    fi

    local c
    for c in git curl awk sed; do
        command -v "$c" >/dev/null 2>&1 && _pf_ok "$c present" || _pf_fail "$c missing"
    done

    [ -f .env ] && _pf_ok ".env present" || _pf_warn ".env missing - defaults will be used (cp .env.example .env)"
    _pf_ok "stack.yml compiles ($(grep -c . "$CONFIG_CACHE") settings)"

    [ -d "$APP_DIR" ] && _pf_ok "repo.root -> $APP_DIR" \
        || _pf_fail "repo.root '$STACK_REPO_ROOT' does not resolve to a directory"

    if [ -d "$GIT_ROOT/.git" ] || git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        _pf_ok "git repository at $GIT_ROOT"
    else
        _pf_warn "no git repository at $GIT_ROOT - 'ssmd wt' and 'ssmd agent' need one"
    fi

    # DNS. Failing here is usually fine and saying so plainly saves a support
    # round-trip: the proxy's catch-all serves the app on the host IP regardless.
    local sub host ip
    for sub in "${STACK_ROUTES_APP}"; do
        host="$sub.$STACK_DOMAIN"
        if ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -n1)" && [ -n "$ip" ]; then
            _pf_ok "$host -> $ip"
        else
            _pf_warn "$host does not resolve from this machine
             (fine if you browse from elsewhere - the proxy catch-all still
              serves http://$(hostname -I 2>/dev/null | awk '{print $1}')/ )"
        fi
    done
    if getent hosts "wildcard-probe-$$.$STACK_DOMAIN" >/dev/null 2>&1; then
        _pf_ok "wildcard *.$STACK_DOMAIN resolves - instance subdomains work automatically"
    else
        _pf_warn "wildcard *.$STACK_DOMAIN does not resolve - each 'ssmd wt add' will
             print a hosts line to add. Point *.$STACK_DOMAIN at this machine
             (dnsmasq, or your router's DNS) to skip that."
    fi

    # Ports. Distinguish "another container holds it" (usually fine, probably
    # this stack already up) from "a host process holds it" (a real conflict).
    if command -v ss >/dev/null 2>&1; then
        local p owner
        for p in "$PROXY_HTTP_PORT" "$PROXY_HTTPS_PORT" "$DB_PORT" "$CACHE_PORT"; do
            [ "$p" = "0" ] && continue
            if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"; then
                owner="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v p=":$p->" '$0 ~ p {print $1}' | head -n1)"
                if [ -z "$owner" ]; then
                    _pf_fail "port $p held by a host process - change it in .env, or stop that process"
                elif [ "${owner#"${STACK_NAME}"-dev}" != "$owner" ]; then
                    # Our own container. Almost always "the stack is already up",
                    # which is not a problem.
                    _pf_ok "port $p held by this stack ($owner)"
                else
                    # Someone else's container. On the derived ports this cannot
                    # happen; on 80/443 it happens constantly, because every ssmd
                    # stack wants them and only one can have them.
                    _pf_fail "port $p held by '$owner', which belongs to a different stack.
             Only one stack can own $p. Stop that one, or set
             PROXY_HTTP_PORT / PROXY_HTTPS_PORT in .env and reach this stack on
             the alternate port."
                fi
            else
                _pf_ok "port $p free"
            fi
        done
    else
        _pf_warn "ss(8) unavailable - cannot check for port conflicts"
    fi

    # A data directory left by the other engine is harmless now that they are
    # separate, but it is worth mentioning: it is disk nobody is using, and its
    # presence usually means someone switched engines and forgot.
    if [ "$DB_ENGINE" != none ]; then
        local other; other="$( [ "$DB_ENGINE" = mysql ] && echo postgres || echo mysql )"
        if [ -d "data/db/$other" ] && [ -n "$(ls -A "data/db/$other" 2>/dev/null)" ]; then
            _pf_warn "data/db/$other holds $(du -sh "data/db/$other" 2>/dev/null | cut -f1) from a
             previous engine. Harmless - the engines no longer share a directory -
             but you can reclaim it: rm -rf data/db/$other"
        fi
    fi

    docker image inspect "$APP_IMAGE" >/dev/null 2>&1 \
        && _pf_ok "app image $APP_IMAGE built" \
        || _pf_warn "app image $APP_IMAGE not built - 'ssmd up' will build it (first build takes a few minutes)"

    # Disk. The image build plus a database import is a couple of GB, and running
    # out mid-build leaves a half-built image and a confusing error.
    local avail min_disk; avail="$(df -Pm . | awk 'NR==2 {print $4}')"
    min_disk="$(_cfg PREFLIGHT_MIN_DISK_MB)"
    if [ "${avail:-0}" -lt "$min_disk" ]; then
        _pf_warn "${avail}MB free here - a build plus an import wants about ${min_disk}MB"
    else _pf_ok "${avail}MB free"; fi

    # Memory. Each agent sandbox is capped at stack.yml's agents.memory; the
    # arithmetic below is the one people get wrong when they raise max_concurrent.
    if [ -r /proc/meminfo ]; then
        local mem_gb; mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
        local want; want=$(( STACK_AGENTS_MAX_CONCURRENT * ${STACK_AGENTS_MEMORY%g} + $(_cfg PREFLIGHT_BASE_MEMORY_GB) ))
        if [ "$mem_gb" -lt "$want" ]; then
            _pf_warn "${mem_gb}GB RAM, but agents.max_concurrent=${STACK_AGENTS_MAX_CONCURRENT} x agents.memory=${STACK_AGENTS_MEMORY}
             plus the base stack wants ~${want}GB. Sandboxes will be OOM-killed
             (exit 137) before the host swaps."
        else
            _pf_ok "${mem_gb}GB RAM - enough for ${STACK_AGENTS_MAX_CONCURRENT} sandboxes at ${STACK_AGENTS_MEMORY}"
        fi
    fi

    declare -F rt_doctor_notes >/dev/null && rt_doctor_notes

    echo
    if [ "$_pf_fails" -gt 0 ]; then
        echo "Preflight: ${_pf_fails} failure(s), ${_pf_warns} warning(s) - fix the failures first"
        return 1
    fi
    echo "Preflight: no failures, ${_pf_warns} warning(s)"
    return 0
}

# ── doctor: drift between ssmd's model and reality ────────────────────────────
# Read-only, always. The reference implementation this borrows from made the same
# choice and it was right: an auto-fixing doctor is a doctor people stop trusting,
# because you can no longer tell what it changed while you were reading its output.
cmd_doctor() {
    _pf_fails=0; _pf_warns=0
    echo "Doctor - drift check for stack '${STACK_NAME}'"
    echo

    # 1. Services the profile set says should be running.
    local want p svc
    want="$(profiles_for_services) $(profiles_for_preset "${SSMD_PRESET:-default}")"
    for svc in app $( [ "$DB_ENGINE" != none ] && echo "$DB_ENGINE" ) \
               $( [ "$CACHE_ENGINE" != none ] && echo "$CACHE_ENGINE" ); do
        if container_running "$svc"; then
            local health
            health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(container "$svc")" 2>/dev/null)"
            case "$health" in
                healthy|none) _pf_ok "$svc running${health:+ ($health)}" ;;
                starting)     _pf_warn "$svc still starting" ;;
                *)            _pf_fail "$svc running but $health - ssmd logs $svc" ;;
            esac
        else
            _pf_fail "$svc not running - ssmd up"
        fi
    done

    # 2. Instance registry vs. what actually exists. Every kind of drift here has
    #    bitten someone: a container removed by hand, a worktree deleted with rm,
    #    a branch gone from the remote, a Traefik/Caddy route left behind.
    if [ "$(instances_count)" != "0" ]; then
        echo
    # Read the whole registry first, then iterate the array.
    #
    # NOT `while read ... < file`: the loop body runs `docker exec -i` (through
    # db_exists) and git, and `docker exec -i` reads stdin - which here IS the
    # registry file. The first instance checked swallows every remaining line, so
    # the loop silently examines one row and reports the rest as clean.
        # Fetched into an array first: the loop body runs `docker exec -i`
        # (through db_exists) and git, and `docker exec -i` reads stdin - which
        # would otherwise be this very result set.
        local rows=(); mapfile -t rows < <(printf "SELECT slug,kind,COALESCE(branch,''),worktree,COALESCE(database,'') FROM instances;" | sq)
        local row
        for row in "${rows[@]}"; do
            [ -z "$row" ] && continue
            IFS="$SSMD_FS" read -r slug kind branch wtpath dbname <<< "$row"
            local prefix="${PROJECT}-${kind}-${slug}"
            docker ps --format '{{.Names}}' | grep -q "^${prefix}-" \
                || _pf_warn "$kind/$slug: registered but no container running"
            [ -d "$wtpath" ] \
                || _pf_fail "$kind/$slug: worktree $wtpath is gone (registry stale - ssmd $kind rm $slug)"
            [ -f "caddy/proxy/sites/${slug}.caddy" ] \
                || _pf_warn "$kind/$slug: no proxy route - https://${slug}.${STACK_DOMAIN} will 404"
            if [ "$DB_ENGINE" != none ] && container_running "$DB_ENGINE"; then
                db_exists "$dbname" || _pf_warn "$kind/$slug: database '$dbname' does not exist"
            fi
            if [ -n "${branch:-}" ] && ! git -C "$GIT_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
                _pf_warn "$kind/$slug: branch '$branch' no longer exists locally"
            fi
        done
    fi

    # 3. Orphan routes: a .caddy file with no registry row. Harmless but it means
    #    a teardown did not finish, and the next instance to reuse that slug gets
    #    a route pointing at a container that is not there.
    local f base
    for f in caddy/proxy/sites/*.caddy; do
        base="$(basename "$f" .caddy)"
        [ "$base" = "00-placeholder" ] && continue
        [ "$(printf 'SELECT COUNT(*) FROM instances WHERE slug=%s;' "$(sq_quote "$base")" | sq1)" != "0" ] \
            || _pf_warn "orphan proxy route caddy/proxy/sites/${base}.caddy - no such instance"
    done

    # 4. Leases that have outlived their TTL. An agent that crashed holds its
    #    sandbox forever otherwise, and the slot count is a hard limit.
    local lrow lslug lmin
    while IFS="$SSMD_FS" read -r lslug lmin; do
        [ -z "$lslug" ] && continue
        _pf_warn "lease on '$lslug' expired ${lmin}m ago - ssmd agent reap"
    done < <(printf "SELECT slug, (strftime('%%s','now') - expires)/60 FROM leases WHERE expires < strftime('%%s','now');" | sq)

    declare -F rt_doctor_notes >/dev/null && rt_doctor_notes

    echo
    if [ "$_pf_fails" -gt 0 ]; then
        echo "Doctor: ${_pf_fails} problem(s), ${_pf_warns} warning(s)"
        return 1
    fi
    echo "Doctor: no problems, ${_pf_warns} warning(s)"
    return 0
}

# Can <container> open a TCP connection to <host>:<port>?
#
# Harder than it should be, because there is no single tool present in every
# runtime image. Three attempts, cheapest first:
#
#   bash's /dev/tcp   present in all four runtime images (Debian-based), but NOT
#                     in `sh` - dash has no /dev/tcp, and invoking it through sh
#                     silently fails, which is what made the first version of
#                     this check report a working database as unreachable.
#   nc -z             present in some images.
#   the language      always present, by definition. The last resort.
tcp_reachable_from() {
    local ctr="$1" host="$2" port="$3"
    docker exec "$ctr" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    docker exec "$ctr" sh -c "nc -z -w3 ${host} ${port}" 2>/dev/null && return 0
    case "$STACK_RUNTIME_KIND" in
        frankenphp) docker exec "$ctr" php -r "exit(@fsockopen('${host}',${port},\$e,\$s,3)?0:1);" 2>/dev/null && return 0 ;;
        node)       docker exec "$ctr" node -e "require('net').createConnection(${port},'${host}').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null && return 0 ;;
        python)     docker exec "$ctr" python -c "import socket,sys; sys.exit(0 if socket.create_connection(('${host}',${port}),3) else 1)" 2>/dev/null && return 0 ;;
    esac
    return 1
}

# ── verify: does the app actually work? ─────────────────────────────────────
# The command an agent runs to check its own work, and the reason the stack ships
# Mailpit and a structured log format at all. It answers with evidence, not with
# "the container is up".
cmd_verify() {
    _pf_fails=0; _pf_warns=0
    local instance="${1:-main}" target
    if [ "$instance" = "main" ]; then target="$(container app)"
    else target="${PROJECT}-wt-${instance}-app"; fi

    echo "Verify - instance '${instance}'"
    echo

    docker ps --format '{{.Names}}' | grep -qx "$target" \
        && _pf_ok "container $target running" \
        || { _pf_fail "container $target not running"; echo; echo "Verify: cannot continue"; return 1; }

    # 1. The web server answers. This is the runtime's own healthz, so a 200 here
    #    and a 500 below cleanly separates "container broken" from "app broken".
    local code
    code="$(docker exec "$target" sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:${STACK_RUNTIME_PORT}${STACK_RUNTIME_HEALTHZ}" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && _pf_ok "healthz 200 (web server alive)" \
                        || _pf_fail "healthz returned $code - the web server itself is unhealthy"

    # 2. The application answers. Through the proxy, by the real hostname, so
    #    routing and TLS are covered too.
    local url_host; url_host="$( [ "$instance" = main ] && echo "${STACK_ROUTES_APP}" || echo "$instance" )"
    code="$(docker exec "$(container proxy)" sh -c \
        "wget -q -S -O /dev/null --no-check-certificate https://${url_host}.${STACK_DOMAIN}/ 2>&1 | awk '/HTTP\\//{print \$2; exit}'" 2>/dev/null || echo 000)"
    case "$code" in
        200|30[0-9]) _pf_ok "GET https://${url_host}.${STACK_DOMAIN}/ -> $code" ;;
        000)         _pf_warn "could not reach the app through the proxy (is the proxy up?)" ;;
        *)           _pf_fail "GET https://${url_host}.${STACK_DOMAIN}/ -> $code" ;;
    esac

    # 3. Backing services reachable *from the app*, which is the only place the
    #    answer matters. A database that is up but unreachable from the app
    #    container is a network problem, and it looks nothing like a down database.
    if [ "$DB_ENGINE" != none ]; then
        if tcp_reachable_from "$target" "$DB_ENGINE" "$(db_internal_port)"; then
            _pf_ok "database reachable from the app container"
        else
            _pf_fail "app cannot reach ${DB_ENGINE}:$(db_internal_port)
             The database may still be initialising - a first-boot MySQL takes
             about a minute to build its data directory. Otherwise it is a
             network problem, not a down database: check both are on the
             '${STACK_NAME}-dev' network."
        fi
        local n; n="$(db_table_count 2>/dev/null)"
        [ "${n:-0}" -gt 0 ] && _pf_ok "database has $n tables" || _pf_fail "database has no tables - ssmd db:migrate"
    fi

    # 4. Errors since the last verify. This is the highest-value check for an
    #    agent: "did what I just did break something" is exactly the question,
    #    and a diff against a stored marker answers it without a human reading
    #    the whole log.
    local marker="data/state/verify-${instance}.since"
    local since; since="$( [ -f "$marker" ] && cat "$marker" || echo "10m" )"
    local errs
    local epat; epat="$(_cfg OUTPUT_ERROR_PATTERN)"
    errs="$(docker logs --since "$since" "$target" 2>&1 | grep -icE "$epat" || true)"
    if [ "${errs:-0}" -gt 0 ]; then
        _pf_fail "$errs error line(s) in the log since $since:"
        docker logs --since "$since" "$target" 2>&1 | grep -iE "$epat" \
            | tail -5 | sed 's/^/           /'
    else
        _pf_ok "no error lines in the log since $since"
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"

    echo
    audit "verify" "instance=$instance fails=$_pf_fails warns=$_pf_warns"
    if [ "$_pf_fails" -gt 0 ]; then
        echo "Verify: ${_pf_fails} failure(s), ${_pf_warns} warning(s)"
        return 1
    fi
    echo "Verify: passing (${_pf_warns} warning(s))"
    return 0
}

# ── status / urls ───────────────────────────────────────────────────────────
cmd_status() {
    printf '%-28s %-12s %-10s %s\n' NAME STATE HEALTH PORTS
    docker ps -a --filter "label=ssmd.stack=${STACK_NAME}" \
        --format '{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    | while IFS=$'\t' read -r n s st p; do
        local h=-
        case "$st" in *"(healthy)"*) h=healthy ;; *"(unhealthy)"*) h=unhealthy ;; *"(health: starting)"*) h=starting ;; esac
        printf '%-28s %-12s %-10s %s\n' "$n" "$s" "$h" "${p:0:40}"
      done
    echo
    cmd_urls
}

cmd_urls() {
    local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    # Include the port whenever it is not the default. A printed URL that does
    # not work is worse than no URL - the reader assumes the stack is broken
    # rather than that the line was wrong.
    local hp="" hs=""
    [ "${PROXY_HTTP_PORT}"  != "80"  ] && hp=":${PROXY_HTTP_PORT}"
    [ "${PROXY_HTTPS_PORT}" != "443" ] && hs=":${PROXY_HTTPS_PORT}"
    cat <<EOF
App        https://${STACK_ROUTES_APP}.${STACK_DOMAIN}${hs}/
           http://${ip:-<this-host>}${hp}/            (catch-all, works with no DNS)
EOF
    container_running mailpit  && echo "Mail       https://mail.${STACK_DOMAIN}${hs}/"
    container_running adminer  && echo "Database   https://db.${STACK_DOMAIN}${hs}/          (auto-login to ${DB_NAME})"
    container_running cache-ui && echo "Cache      https://cache.${STACK_DOMAIN}${hs}/"
    container_running minio    && echo "Storage    https://minio.${STACK_DOMAIN}${hs}/       S3: https://s3.${STACK_DOMAIN}${hs}/"
    container_running browser  && echo "Browser    https://vnc.${STACK_DOMAIN}${hs}/         (watch an e2e run live)"
    container_running mcp      && echo "MCP        http://127.0.0.1:${MCP_PORT}/         (stack control for Claude Code)"
    echo
    [ "$DB_ENGINE" != none ]  && echo "  ${DB_ENGINE}     ${DB_BIND}:${DB_PORT}   db ${DB_NAME}, user ${DB_USER}"
    [ "$CACHE_ENGINE" != none ] && echo "  ${CACHE_ENGINE}     ${CACHE_BIND}:${CACHE_PORT}"

    local n; n="$(instances_count 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && { echo; echo "  ${n} instance(s) running - ssmd wt ls"; }

    echo
    echo "Certificate warning in the browser?  ssmd ca-cert"
}

cmd_describe() {
    cat <<EOF
Stack       ${STACK_NAME}
Domain      ${STACK_DOMAIN}
Runtime     $(rt_display_name)
Repo        ${APP_DIR}
Git root    ${GIT_ROOT}
Worktrees   ${WORKTREE_ROOT}
Project     ${PROJECT}
Image       ${APP_IMAGE}
Port offset ${PORT_OFFSET}   (derived from name@domain; stable across restarts)

Services    database=${DB_ENGINE} cache=${CACHE_ENGINE} mail=${MAIL_ENGINE} storage=${STORAGE_ENGINE}
            search=${SEARCH_ENGINE} vector=${VECTOR_ENGINE}
            queue=${STACK_SERVICES_QUEUE} scheduler=${STACK_SERVICES_SCHEDULER}

Agents      max_concurrent=${STACK_AGENTS_MAX_CONCURRENT} cpus=${STACK_AGENTS_CPUS}
            memory=${STACK_AGENTS_MEMORY} egress=${STACK_AGENTS_EGRESS} lease_ttl=${STACK_AGENTS_LEASE_TTL}

Verbs       $(rt_verbs)
EOF
}

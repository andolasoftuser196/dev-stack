# lib/core.sh - bootstrap, compose plumbing, output, audit.
#
# Sourced by dx before anything else. Everything here is side-effect-free except
# load_config, which is the one function allowed to touch the environment.
#
# The rule this file exists to enforce: **no value that belongs to a project or a
# machine appears in code**. Everything comes from the config database
# (lib/config.sh), which is seeded from config/*.yml. If you find yourself
# writing a literal port, image tag, timeout or threshold below, it belongs in
# config/defaults.yml instead.

set -euo pipefail

# ── output ──────────────────────────────────────────────────────────────────
# Colour only when stdout is a terminal. dx output is routinely piped into a log
# or read back by an agent through the MCP server, and escape codes there are
# noise the model then tries to interpret.
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
else
    C_DIM=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_OFF=''
fi

log()  { printf '%s[dx]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '  %s[OK]%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YLW" "$C_OFF" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { printf '%s[dx] ERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hint() { printf '%s      %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# ── host sanity ─────────────────────────────────────────────────────────────
require_host_os() {
    case "$(uname -s)" in
        Linux*|Darwin*) ;;
        *)
            die "unsupported host OS '$(uname -s)'. Linux or macOS only.
      On Windows use WSL2 with the repo on the ext4 filesystem - a bind mount
      from /mnt/c makes every file operation 10-50x slower and breaks inotify."
            ;;
    esac
}

# ── bootstrap ───────────────────────────────────────────────────────────────
# .env carries bootstrap only: where the config store is, which host profile
# applies, and secret material that must never be committed. It is deliberately
# NOT a configuration file - everything else lives in the database.
#
# A missing .env is fine. Every bootstrap value has a default; the file exists
# for the machine that needs a different one.
load_bootstrap() {
    cd "$DX_ROOT"
    [ -f .env ] && { set -a; . ./.env; set +a; }

    export DX_DB_PATH="${DX_DB:-config/dx.db}"
    case "$DX_DB_PATH" in /*) ;; *) DX_DB_PATH="$DX_ROOT/$DX_DB_PATH" ;; esac
    export DX_HOST="${DX_HOST:-local}"
    export DX_ACTOR="${DX_ACTOR:-${USER:-unknown}}"
}

load_config() {
    load_bootstrap
    config_load          # lib/config.sh - resolves the layers into $STACK_*

    : "${STACK_NAME:?config has no 'name' - check config/stack.yml}"
    : "${STACK_DOMAIN:?config has no 'domain' - check config/stack.yml}"
    : "${STACK_RUNTIME_KIND:?config has no 'runtime.kind' - check config/stack.yml}"

    # Containers run as the invoking user so that files they create in the
    # bind-mounted repo are editable on the host. The single most common source
    # of "permission denied" in a Docker dev stack, and the fix is one line - so
    # it is not configurable.
    export HOST_UID; HOST_UID="$(id -u)"
    export HOST_GID; HOST_GID="$(id -g)"

    export PROJECT="${STACK_NAME}-dev"

    [ -d "$STACK_REPO_ROOT" ] || die "repo.root '$STACK_REPO_ROOT' is not a directory.
      It is resolved relative to $DX_ROOT, and it must point at the application
      source - the tree that gets bind-mounted into the app container.
        dx config set repo.root ../my-app"
    export APP_DIR;  APP_DIR="$(cd "$STACK_REPO_ROOT" && pwd)"

    local gr="${STACK_REPO_GIT_ROOT:-$STACK_REPO_ROOT}"
    [ -d "$gr" ] || die "repo.git_root '$gr' is not a directory.
      Worktree and agent instances are created from it; set it to the
      repository root when repo.root is a subdirectory of a monorepo.
        dx config set repo.git_root ../.."
    export GIT_ROOT; GIT_ROOT="$(cd "$gr" && pwd)"

    case "${STACK_REPO_WORKTREE_ROOT}" in
        /*) export WORKTREE_ROOT="${STACK_REPO_WORKTREE_ROOT}" ;;
        *)  export WORKTREE_ROOT="$DX_ROOT/${STACK_REPO_WORKTREE_ROOT}" ;;
    esac

    export RUNTIME_DIR="$DX_ROOT/runtimes/$STACK_RUNTIME_KIND"
    [ -d "$RUNTIME_DIR" ] || die "unknown runtime '$STACK_RUNTIME_KIND'.
      Available: $(cd "$DX_ROOT/runtimes" && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')
      Set it with: dx config set runtime.kind <name>"

    derive_images
    derive_ports
    derive_services
}

# ── derived values ──────────────────────────────────────────────────────────
# Everything below is computed from config. None of it introduces a new
# constant; each line either reads a config key or combines two.

_cfg() {  # _cfg <SHELL_VAR_SUFFIX> - read a resolved config value, or die
    local var="STACK_$1"
    local v="${!var:-}"
    [ -n "$v" ] || die "config key for \$$var is missing.
      The toolkit defaults should provide it: dx config import
      Or set it: dx config set $(printf '%s' "$1" | tr 'A-Z_' 'a-z.') <value>"
    printf '%s' "$v"
}

_cfgd() {  # _cfgd <SUFFIX> <default> - read, tolerating absence
    local var="STACK_$1"; printf '%s' "${!var:-$2}"
}

derive_images() {
    # The runtime image tag is a template in config, so bumping a language
    # version is one field in stack.yml rather than an edit to a Dockerfile.
    local tmpl; tmpl="$(_cfg "RUNTIME_IMAGES_$(printf '%s' "$STACK_RUNTIME_KIND" | tr '[:lower:]' '[:upper:]')")"
    export RUNTIME_BASE_IMAGE="${tmpl//\{version\}/${STACK_RUNTIME_VERSION}}"

    export APP_IMAGE="${STACK_NAME}-dev/${STACK_RUNTIME_KIND}:${STACK_RUNTIME_VERSION}"
    export SANDBOX_IMAGE="${STACK_NAME}-dev/sandbox:latest"
    export EGRESS_IMAGE="${STACK_NAME}-dev/egress:latest"

    # Backing-service images. The database tag combines the image name from the
    # toolkit defaults with the version from the project.
    export IMAGE_PROXY;      IMAGE_PROXY="$(_cfg IMAGES_PROXY)"
    export IMAGE_REDIS;      IMAGE_REDIS="$(_cfg IMAGES_REDIS)"
    export IMAGE_MAILPIT;    IMAGE_MAILPIT="$(_cfg IMAGES_MAILPIT)"
    export IMAGE_MINIO;      IMAGE_MINIO="$(_cfg IMAGES_MINIO)"
    export IMAGE_MEILI;      IMAGE_MEILI="$(_cfg IMAGES_MEILISEARCH)"
    export IMAGE_PGVECTOR;   IMAGE_PGVECTOR="$(_cfg IMAGES_PGVECTOR)"
    export IMAGE_DB_UI;      IMAGE_DB_UI="$(_cfg IMAGES_DB_UI)"
    export IMAGE_CACHE_UI;   IMAGE_CACHE_UI="$(_cfg IMAGES_CACHE_UI)"
    export IMAGE_BROWSER;    IMAGE_BROWSER="$(_cfg IMAGES_BROWSER)"
    export IMAGE_MCP;        IMAGE_MCP="$(_cfg IMAGES_MCP)"
    export IMAGE_HELPER;     IMAGE_HELPER="$(_cfg IMAGES_HELPER)"
    export IMAGE_EGRESS_BASE; IMAGE_EGRESS_BASE="$(_cfg IMAGES_EGRESS_BASE)"
}

# Several dx stacks on one host would otherwise all want the same ports. Derive
# a stable offset from the project identity: same project, same ports forever;
# different projects, near-certainly different. cksum is POSIX and spreads well
# enough for the configured span.
derive_ports() {
    local span span_min h
    span="$(_cfg PORT_OFFSET_SPAN)"; span_min="$(_cfg PORT_OFFSET_SPAN_MIN)"
    h="$(printf '%s@%s' "$STACK_NAME" "$STACK_DOMAIN" | cksum | awk '{print $1}')"
    export PORT_OFFSET=$(( h % span + span_min ))

    # The proxy is not offset: a dev domain is only useful without a port suffix
    # in the URL, so these come from the host profile and a collision is a real
    # conflict that preflight reports by name.
    export PROXY_BIND;       PROXY_BIND="$(_cfg PROXY_BIND)"
    export PROXY_HTTP_PORT;  PROXY_HTTP_PORT="$(_cfg PROXY_HTTP)"
    export PROXY_HTTPS_PORT; PROXY_HTTPS_PORT="$(_cfg PROXY_HTTPS)"
    export DB_BIND;          DB_BIND="$(_cfg BIND_DATABASE)"
    export CACHE_BIND;       CACHE_BIND="$(_cfg BIND_CACHE)"

    export DB_PORT=$(( $(_cfg PORT_OFFSET_BASE_DB)      + PORT_OFFSET ))
    export CACHE_PORT=$(( $(_cfg PORT_OFFSET_BASE_CACHE) + PORT_OFFSET ))
    export S3_PORT=$(( $(_cfg PORT_OFFSET_BASE_STORAGE)  + PORT_OFFSET ))
    export VNC_PORT=$(( $(_cfg PORT_OFFSET_BASE_VNC)     + PORT_OFFSET ))
    export MCP_PORT=$(( $(_cfg PORT_OFFSET_BASE_MCP)     + PORT_OFFSET ))

    # Container-internal ports, from config because they are properties of the
    # images and change when an image does.
    export PORT_MAIL_SMTP;     PORT_MAIL_SMTP="$(_cfg PORTS_MAIL_SMTP)"
    export PORT_MAIL_UI;       PORT_MAIL_UI="$(_cfg PORTS_MAIL_UI)"
    export PORT_MINIO_S3;      PORT_MINIO_S3="$(_cfg PORTS_MINIO_S3)"
    export PORT_MINIO_CONSOLE; PORT_MINIO_CONSOLE="$(_cfg PORTS_MINIO_CONSOLE)"
    export PORT_DB_UI;         PORT_DB_UI="$(_cfg PORTS_DB_UI)"
    export PORT_CACHE_UI;      PORT_CACHE_UI="$(_cfg PORTS_CACHE_UI)"
    export PORT_BROWSER_NOVNC; PORT_BROWSER_NOVNC="$(_cfg PORTS_BROWSER_NOVNC)"
    export PORT_BROWSER_VNC;   PORT_BROWSER_VNC="$(_cfg PORTS_BROWSER_VNC)"
    export PORT_MCP_INTERNAL;  PORT_MCP_INTERNAL="$(_cfg PORTS_MCP)"
    export PORT_EGRESS;        PORT_EGRESS="$(_cfg PORTS_EGRESS)"
    export PORT_REDIS;         PORT_REDIS="$(_cfg PORTS_REDIS)"

    # Inner port the app process listens on, behind the runtime's own Caddy.
    export DX_APP_PORT; DX_APP_PORT="$(_cfg "APP_PORTS_$(printf '%s' "$STACK_RUNTIME_KIND" | tr '[:lower:]' '[:upper:]')")"
}

derive_services() {
    export DB_ENGINE="${STACK_SERVICES_DATABASE}"
    export CACHE_ENGINE="${STACK_SERVICES_CACHE}"
    export MAIL_ENGINE="${STACK_SERVICES_MAIL}"
    export STORAGE_ENGINE="${STACK_SERVICES_STORAGE}"
    export SEARCH_ENGINE="${STACK_SERVICES_SEARCH}"
    export VECTOR_ENGINE="${STACK_SERVICES_VECTOR}"

    # Defaulted, not required: a project with services.database: none has no
    # `database:` block at all, and under `set -u` a bare reference aborts dx
    # before it can say anything useful. These values are unused in that case -
    # db_require() is what refuses the operations that would need them - but
    # compose still interpolates them, so they must exist.
    export DB_NAME;     DB_NAME="$(_cfgd DATABASE_NAME "${STACK_NAME}_dev")"
    export DB_USER;     DB_USER="$(_cfgd DATABASE_USER "$STACK_NAME")"
    export DB_PASSWORD; DB_PASSWORD="$(_cfgd DATABASE_PASSWORD "$STACK_NAME")"

    case "$DB_ENGINE" in
        mysql)    export DB_IMAGE="$(_cfg IMAGES_MYSQL):$(_cfgd DATABASE_VERSION 8.0)"
                  export DB_INTERNAL_PORT; DB_INTERNAL_PORT="$(_cfg PORTS_MYSQL)" ;;
        postgres) export DB_IMAGE="$(_cfg IMAGES_POSTGRES):$(_cfgd DATABASE_VERSION 16)"
                  export DB_INTERNAL_PORT; DB_INTERNAL_PORT="$(_cfg PORTS_POSTGRES)" ;;
        *)
            # No database. The mysql/postgres service definitions still have to
            # PARSE - `docker compose config` validates the whole file, not just
            # the profiles being started - and a target port of 0 is rejected.
            # So this stays a real port number that nothing will ever connect to;
            # db_require() is what actually stops anyone using it.
            export DB_IMAGE=""
            export DB_INTERNAL_PORT; DB_INTERNAL_PORT="$(_cfg PORTS_MYSQL)" ;;
    esac

    # Service tuning, all from config.
    export TUNE_MYSQL_BUFFER;   TUNE_MYSQL_BUFFER="$(_cfg TUNING_MYSQL_BUFFER_POOL)"
    export TUNE_MYSQL_CONNS;    TUNE_MYSQL_CONNS="$(_cfg TUNING_MYSQL_MAX_CONNECTIONS)"
    export TUNE_MYSQL_CHARSET;  TUNE_MYSQL_CHARSET="$(_cfg TUNING_MYSQL_CHARSET)"
    export TUNE_MYSQL_COLLATE;  TUNE_MYSQL_COLLATE="$(_cfg TUNING_MYSQL_COLLATION)"
    export TUNE_REDIS_MAXMEM;   TUNE_REDIS_MAXMEM="$(_cfg TUNING_REDIS_MAXMEMORY)"
    export TUNE_REDIS_POLICY;   TUNE_REDIS_POLICY="$(_cfg TUNING_REDIS_MAXMEMORY_POLICY)"
    export TUNE_MAIL_MAX;       TUNE_MAIL_MAX="$(_cfg TUNING_MAIL_MAX_MESSAGES)"
    export TUNE_BROWSER_SHM;    TUNE_BROWSER_SHM="$(_cfg TUNING_BROWSER_SHM)"
    export TUNE_BROWSER_SCREEN; TUNE_BROWSER_SCREEN="$(_cfg TUNING_BROWSER_SCREEN)"
    export WORKER_MAX_RUNTIME;  WORKER_MAX_RUNTIME="$(_cfg TUNING_WORKER_MAX_RUNTIME)"
    export QUEUE_TRIES;         QUEUE_TRIES="$(_cfg TUNING_QUEUE_TRIES)"
    export QUEUE_TIMEOUT;       QUEUE_TIMEOUT="$(_cfg TUNING_QUEUE_TIMEOUT)"

    # PHP settings reach php.dev.ini through the environment, so changing one is
    # a config change rather than an image rebuild.
    export PHP_MEMORY_LIMIT;    PHP_MEMORY_LIMIT="$(_cfgd PHP_MEMORY_LIMIT 512M)"
    export PHP_MAX_EXECUTION;   PHP_MAX_EXECUTION="$(_cfgd PHP_MAX_EXECUTION_TIME 300)"
    export PHP_POST_MAX;        PHP_POST_MAX="$(_cfgd PHP_POST_MAX_SIZE 64M)"
    export PHP_UPLOAD_MAX;      PHP_UPLOAD_MAX="$(_cfgd PHP_UPLOAD_MAX_FILESIZE 64M)"
    export PHP_MAX_INPUT_VARS;  PHP_MAX_INPUT_VARS="$(_cfgd PHP_MAX_INPUT_VARS 5000)"
    export PHP_OPCACHE_MEMORY;  PHP_OPCACHE_MEMORY="$(_cfgd PHP_OPCACHE_MEMORY 256)"
    export PHP_OPCACHE_FILES;   PHP_OPCACHE_FILES="$(_cfgd PHP_OPCACHE_MAX_FILES 20000)"
    export PHP_TIMEZONE;        PHP_TIMEZONE="$(_cfgd PHP_TIMEZONE UTC)"
    export PHP_REQUEST_BODY;    PHP_REQUEST_BODY="$(_cfgd PHP_REQUEST_BODY_MAX 64MiB)"
    export PHPSTAN_MEMORY;      PHPSTAN_MEMORY="$(_cfgd PHP_PHPSTAN_MEMORY 1G)"

    derive_app_env

    export XDEBUG_MODE="${XDEBUG_MODE:-$(_cfgd XDEBUG_MODE off)}"
    export S3_KEY="${S3_KEY:-$(_cfgd STORAGE_KEY minioadmin)}"
    export S3_SECRET="${S3_SECRET:-$(_cfgd STORAGE_SECRET minioadmin)}"
    export S3_BUCKET="${STACK_NAME}"
}

# The driver names an application reads, as opposed to the connection details
# it reads. A framework will not infer the driver from the fact that a database
# host was provided - Laravel 11 defaults to sqlite and then reports a missing
# file, which points nowhere near the actual configuration.
derive_app_env() {
    case "$DB_ENGINE" in
        mysql)    export DB_CONNECTION; DB_CONNECTION="$(_cfgd APP_ENV_DB_CONNECTION_MYSQL mysql)" ;;
        postgres) export DB_CONNECTION; DB_CONNECTION="$(_cfgd APP_ENV_DB_CONNECTION_POSTGRES pgsql)" ;;
        *)        export DB_CONNECTION="" ;;
    esac

    if [ "$CACHE_ENGINE" = none ]; then
        export CACHE_DRIVER;     CACHE_DRIVER="$(_cfgd APP_ENV_FALLBACK_CACHE file)"
        export SESSION_DRIVER="$CACHE_DRIVER"
        export QUEUE_CONNECTION; QUEUE_CONNECTION="$(_cfgd APP_ENV_FALLBACK_QUEUE sync)"
    else
        export CACHE_DRIVER;     CACHE_DRIVER="$(_cfgd APP_ENV_CACHE_DRIVER redis)"
        export SESSION_DRIVER;   SESSION_DRIVER="$(_cfgd APP_ENV_SESSION_DRIVER redis)"
        export QUEUE_CONNECTION; QUEUE_CONNECTION="$(_cfgd APP_ENV_QUEUE_CONNECTION redis)"
    fi
    export REDIS_CLIENT; REDIS_CLIENT="$(_cfgd APP_ENV_REDIS_CLIENT phpredis)"
    export MAIL_MAILER;  MAIL_MAILER="$(_cfgd APP_ENV_MAIL_MAILER smtp)"

    # DATABASE_URL, assembled from the parts dx already knows. Empty when there
    # is no database, so a framework reading it gets nothing rather than a URL
    # pointing at a host that does not exist.
    case "$DB_ENGINE" in
        mysql)    export DATABASE_URL="$(_cfgd APP_ENV_DATABASE_URL_SCHEME_MYSQL mysql)://${DB_USER}:${DB_PASSWORD}@${DB_ENGINE}:${DB_INTERNAL_PORT}/${DB_NAME}" ;;
        postgres) export DATABASE_URL="$(_cfgd APP_ENV_DATABASE_URL_SCHEME_POSTGRES postgresql)://${DB_USER}:${DB_PASSWORD}@${DB_ENGINE}:${DB_INTERNAL_PORT}/${DB_NAME}" ;;
        *)        export DATABASE_URL="" ;;
    esac

    if [ "$STORAGE_ENGINE" = none ]; then
        export FILESYSTEM_DISK; FILESYSTEM_DISK="$(_cfgd APP_ENV_FALLBACK_FILESYSTEM local)"
    else
        export FILESYSTEM_DISK; FILESYSTEM_DISK="$(_cfgd APP_ENV_FILESYSTEM_DISK s3)"
    fi
}

# ── profiles ────────────────────────────────────────────────────────────────
# Read from config, not declared here. A profile missing from profiles.all
# becomes a container `dx down` silently leaves running, which is why the list
# is a single config value rather than a constant in each of three files.
all_profiles() { printf '%s' "$(_cfg PROFILES_ALL)"; }

profiles_for_preset() {
    local var="STACK_PRESETS_$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
    # An unset preset is an error; a preset set to the empty string ("core") is
    # not. `declare -p` distinguishes them where `[ -z ]` cannot.
    declare -p "$var" >/dev/null 2>&1 || return 1
    printf '%s' "${!var}"
}

# compgen, not `set | grep`: `set` also prints function bodies, and a function
# containing the string STACK_PRESETS_ would show up as a preset.
preset_names() {
    compgen -v | grep '^STACK_PRESETS_' | sed 's/^STACK_PRESETS_//' \
        | tr '[:upper:]_' '[:lower:]-' | sort
}

# Profiles implied by the service selection, regardless of preset. An app
# configured for postgres always gets postgres; that is not a preset choice.
profiles_for_services() {
    local p=()
    [ "$DB_ENGINE"      != none ] && p+=("$DB_ENGINE")
    [ "$CACHE_ENGINE"   != none ] && p+=("$CACHE_ENGINE")
    [ "$MAIL_ENGINE"    != none ] && p+=("$MAIL_ENGINE")
    [ "$STORAGE_ENGINE" != none ] && p+=("$STORAGE_ENGINE")
    [ "$SEARCH_ENGINE"  != none ] && p+=("$SEARCH_ENGINE")
    [ "$VECTOR_ENGINE"  != none ] && p+=("$VECTOR_ENGINE")
    echo "${p[@]:-}"
}

profile_args() {
    local p
    for p in "$@"; do [ -n "$p" ] && printf -- '--profile\n%s\n' "$p"; done
}

# ── compose ─────────────────────────────────────────────────────────────────
# One place that knows the project name and the file list. Nothing in dx calls
# `docker compose` directly; that indirection is what makes it possible to add a
# file without auditing every call site.
compose() {
    local args=(-p "$PROJECT" -f docker-compose.yml)
    [ -f docker-compose.override.yml ] && args+=(-f docker-compose.override.yml)
    docker compose "${args[@]}" "$@"
}

compose_all_profiles() {
    local pargs=(); mapfile -t pargs < <(profile_args $(all_profiles))
    compose "${pargs[@]}" "$@"
}

# `docker exec -it` hard-errors with "cannot attach stdin to a TTY-enabled
# container" when there is no terminal, which breaks every one of these commands
# under CI, a cron entry, an MCP call or a plain pipe. Ask for a TTY only when
# one exists - the single most common reason an agent's dx call fails where the
# human's identical call succeeded.
dexec() {
    if [ -t 0 ] && [ -t 1 ]; then docker exec -it "$@"; else docker exec "$@"; fi
}

container() { echo "${PROJECT}-$1"; }

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container "$1")"
}

require_running() {
    container_running "$1" || die "service '$1' is not running. Start it: dx up"
}

# ── runtime module dispatch ─────────────────────────────────────────────────
load_runtime() {
    [ -f "$RUNTIME_DIR/commands.sh" ] || die "runtime '$STACK_RUNTIME_KIND' has no commands.sh"
    # shellcheck disable=SC1090
    . "$RUNTIME_DIR/commands.sh"
}

# ── misc ────────────────────────────────────────────────────────────────────
# Tolerant of a read-only root, because inside an agent sandbox that is exactly
# what it is. A read-only mount must degrade dx to "cannot record", never to
# "cannot run".
ensure_dirs() {
    local d
    # data/db/<engine>: the two engines must never share a data directory, or
    # switching services.database leaves the other's files behind and the new
    # engine refuses to initialise.
    for d in data/snapshots data/caddy-config data/proxy data/cache \
             data/db/mysql data/db/postgres \
             data/storage data/agent data/build-cache data/state; do
        [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
    done
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's#[^a-z0-9]\+#-#g' -e 's#^-\+##' -e 's#-\+$##' \
        | cut -c1-32
}

# Append to the audit table. Every state-changing dx command calls this, which
# is what makes `dx audit` able to answer "what did the agent actually do"
# without trusting the agent's own account of it.
#
# Best-effort by design: a read-only mount or a locked database must never be
# the reason a command refuses to run. The controls that stop things are in
# policy.sh and db.sh, and those fail closed.
audit() {
    local event="$1"; shift
    printf 'INSERT INTO audit(ts, actor, event, detail) VALUES(%s,%s,%s,%s);' \
        "$(sq_quote "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
        "$(sq_quote "${DX_ACTOR:-unknown}")" \
        "$(sq_quote "$event")" \
        "$(sq_quote "${*:-}")" | sq >/dev/null 2>&1 || true
}

confirm() {
    # An agent must never be able to answer its own confirmation prompt. With no
    # terminal the answer is "no" unless DX_YES was set explicitly by whoever
    # invoked dx.
    [ "${DX_YES:-}" = "1" ] && return 0
    if [ ! -t 0 ]; then
        die "'$1' needs confirmation and there is no terminal.
      Re-run interactively, or set DX_YES=1 if you are certain."
    fi
    printf '%s [y/N] ' "$1"; local a; read -r a
    [ "$a" = "y" ] || [ "$a" = "Y" ]
}

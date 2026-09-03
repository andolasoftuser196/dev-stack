# Go runtime. Unlike the interpreted runtimes, "hot reload" means recompiling -
# air watches the tree and restarts the binary. Caddy still fronts it so that
# healthz answers during the two seconds a rebuild takes, instead of the
# container flapping on every save.
# The base image is passed in whole, resolved from runtime_images.go in the
# config database with {version} substituted. No tag is written here: a
# literal would be a second place to bump a version and the two would drift.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG EXTRA_PACKAGES=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git curl ca-certificates jq less procps tini \
        default-mysql-client postgresql-client \
        debian-keyring debian-archive-keyring apt-transport-https gnupg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
         | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
         > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends caddy \
    && if [ -n "$EXTRA_PACKAGES" ]; then \
         apt-get install -y --no-install-recommends $(echo "$EXTRA_PACKAGES" | tr '\n' ' '); \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Versions come from go_tools.* in config, never `@latest`. See the note there:
# `@latest` resolves to whatever the tool released this morning, which may
# require a newer Go than this image has - and then the build fails on a machine
# where nothing changed.
ARG AIR_VERSION
ARG DELVE_VERSION
ARG STATICCHECK_VERSION
RUN go install github.com/air-verse/air@${AIR_VERSION} \
    && go install github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION} \
    && go install honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VERSION}

# GOPATH and the build cache go on the shared bind mount. A cold Go build cache
# is the difference between a 4-second and a 90-second restart, and every
# worktree instance would otherwise start cold.
ENV HOME=/ssmd/cache/home \
    GOPATH=/ssmd/cache/go \
    GOCACHE=/ssmd/cache/go-build \
    GOMODCACHE=/ssmd/cache/go-mod \
    XDG_CONFIG_HOME=/ssmd/cache/config \
    PATH=/go/bin:/ssmd/cache/go/bin:$PATH \
    CGO_ENABLED=1

COPY serve.conf /etc/caddy/Caddyfile
COPY air.toml /ssmd/air.toml
COPY entrypoint.sh /usr/local/bin/ssmd-entrypoint
RUN chmod +x /usr/local/bin/ssmd-entrypoint \
    && mkdir -p /ssmd/cache && chmod -R 777 /ssmd

WORKDIR /app
ENTRYPOINT ["/usr/bin/tini", "--", "ssmd-entrypoint"]
CMD ["serve"]

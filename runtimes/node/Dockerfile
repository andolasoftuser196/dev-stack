# Node runtime. The app process listens on an inner port; a small Caddy in front
# owns $SSMD_PORT, answers $SSMD_HEALTHZ itself, and serves static files.
#
# That front layer is why every ssmd runtime behaves identically: healthz keeps
# answering while the app process is crash-looping, which is exactly when you
# need the container to stay up so you can read its logs.
# The base image is passed in whole, resolved from runtime_images.node in the
# config database with {version} substituted. No tag is written here: a
# literal would be a second place to bump a version and the two would drift.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG EXTRA_PACKAGES=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git curl ca-certificates jq less procps tini \
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

# Corepack pins the package manager from package.json's "packageManager" field,
# so a project using pnpm or yarn gets the version it declares rather than
# whatever npm happens to ship.
RUN corepack enable

ENV HOME=/ssmd/cache/home \
    NPM_CONFIG_CACHE=/ssmd/cache/npm \
    YARN_CACHE_FOLDER=/ssmd/cache/yarn \
    PNPM_HOME=/ssmd/cache/pnpm \
    XDG_CONFIG_HOME=/ssmd/cache/config \
    XDG_CACHE_HOME=/ssmd/cache/xdg

COPY serve.conf /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/ssmd-entrypoint
RUN chmod +x /usr/local/bin/ssmd-entrypoint \
    && mkdir -p /ssmd/cache && chmod -R 777 /ssmd

WORKDIR /app
ENTRYPOINT ["/usr/bin/tini", "--", "ssmd-entrypoint"]
CMD ["serve"]

# Python runtime. Same shape as the others: Caddy owns $SSMD_PORT and answers
# healthz; the ASGI/WSGI server listens on an inner port.
# The base image is passed in whole, resolved from runtime_images.python in the
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

# uv resolves and installs an order of magnitude faster than pip, which matters
# here because a worktree instance re-resolves on every create. It falls back to
# pip transparently for projects that only ship a requirements.txt.
RUN pip install --no-cache-dir uv

# UV_CACHE_DIR is shared and PIP_CACHE_DIR with it: the download cache is what
# makes a new instance install fast, and it is safe to share because it is
# content-addressed.
#
# The venv is NOT shared, and must not be. It used to live at a single fixed
# path, so two worktree instances of branches with different dependencies
# overwrote each other's site-packages - and the loser failed with
# ModuleNotFoundError for a package plainly listed in its own manifest. The path
# comes from SSMD_VENV, which compose sets per instance.
ENV HOME=/ssmd/cache/home \
    PIP_CACHE_DIR=/ssmd/cache/pip \
    UV_CACHE_DIR=/ssmd/cache/uv \
    XDG_CONFIG_HOME=/ssmd/cache/config \
    XDG_CACHE_HOME=/ssmd/cache/xdg \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SSMD_VENV=/ssmd/cache/venv/main

COPY serve.conf /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/ssmd-entrypoint
RUN chmod +x /usr/local/bin/ssmd-entrypoint \
    && mkdir -p /ssmd/cache && chmod -R 777 /ssmd

WORKDIR /app
ENTRYPOINT ["/usr/bin/tini", "--", "ssmd-entrypoint"]
CMD ["serve"]

# FrankenPHP: Caddy with PHP embedded. One process serves HTTP and executes PHP,
# which removes the php-fpm socket and the second config file that goes with it.
#
# Classic mode only - no `worker` directive. See serve.conf.
# The base image is passed in whole, resolved from runtime_images.frankenphp in the
# config database with {version} substituted. No tag is written here: a
# literal would be a second place to bump a version and the two would drift.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG EXTRA_PACKAGES=""

# install-php-extensions ships in this image and handles the build-deps dance
# (install, compile, purge) that otherwise adds 400MB of gcc to the layer.
RUN install-php-extensions \
        pdo_mysql pdo_pgsql pgsql mysqli \
        gd zip intl bcmath exif pcntl sockets \
        redis opcache xdebug \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        git unzip curl ca-certificates jq less procps \
        default-mysql-client postgresql-client \
    && if [ -n "$EXTRA_PACKAGES" ]; then \
         apt-get install -y --no-install-recommends $(echo "$EXTRA_PACKAGES" | tr '\n' ' '); \
       fi \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# The container runs as the invoking host user, whose UID does not exist in this
# image's /etc/passwd. Everything that would normally live in $HOME is redirected
# to /ssmd/cache, a bind mount ssmd creates - so composer's cache survives rebuilds
# and is shared across instances instead of being re-downloaded per worktree.
ENV HOME=/ssmd/cache/home \
    COMPOSER_HOME=/ssmd/cache/composer \
    COMPOSER_ALLOW_SUPERUSER=1 \
    XDG_CONFIG_HOME=/ssmd/cache/config \
    XDG_CACHE_HOME=/ssmd/cache/xdg

# php.ini and the Caddy config are copied rather than mounted so that the image
# is self-sufficient; ssmd bind-mounts over them only when you ask for prod parity.
COPY php.dev.ini  /usr/local/etc/php/conf.d/zz-ssmd-dev.ini
COPY xdebug.ini   /usr/local/etc/php/conf.d/zz-ssmd-xdebug.ini
COPY serve.conf   /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/ssmd-entrypoint
RUN chmod +x /usr/local/bin/ssmd-entrypoint \
    && mkdir -p /ssmd/cache /data /config \
    && chmod -R 777 /ssmd /data /config

WORKDIR /app
ENTRYPOINT ["ssmd-entrypoint"]
CMD ["serve"]

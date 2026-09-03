# The only route off this box for an agent sandbox.
#
# tinyproxy rather than squid: the filter is a plain regex file, the config is
# twenty lines, and the whole image is under 10MB. Squid's ACL language is more
# capable and nobody reviewing this would read it.
#
# What this enforces: CONNECT and GET are matched against the allowlist by
# hostname, and FilterDefaultDeny makes everything else a 403. What it does not
# enforce: anything that does not speak HTTP proxy. That is intentional and it is
# the isolated network's job - a sandbox has no gateway, so a non-proxy-aware
# tool does not get out by another route, it simply fails.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apk add --no-cache tinyproxy ca-certificates tini

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY entrypoint.sh  /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint && mkdir -p /etc/egress /var/log/egress

EXPOSE 8888
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]

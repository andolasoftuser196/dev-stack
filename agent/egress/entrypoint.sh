#!/bin/sh
# Compile policy/allow-hosts.txt into a tinyproxy filter file, then serve.
set -eu

SRC=/etc/egress/allow-hosts.txt
OUT=/etc/egress/filter.re
CONF=/etc/egress/tinyproxy.conf

: "${EGRESS_PORT:=8888}"
: "${EGRESS_TIMEOUT:=600}"
: "${EGRESS_MAX_CLIENTS:=100}"
: "${EGRESS_CONNECT_PORTS:=443 80}"

# tinyproxy's config format has no variables, so the shipped file carries
# placeholders and they are substituted once at boot from the environment.
render_conf() {
    connect=""
    for p in $EGRESS_CONNECT_PORTS; do connect="${connect}ConnectPort ${p}\n"; done
    sed -e "s/__EGRESS_PORT__/${EGRESS_PORT}/" \
        -e "s/__EGRESS_TIMEOUT__/${EGRESS_TIMEOUT}/" \
        -e "s/__EGRESS_MAX_CLIENTS__/${EGRESS_MAX_CLIENTS}/" \
        -e "s|__CONNECT_PORTS__|${connect%\\n}|" \
        /etc/tinyproxy/tinyproxy.conf > "$CONF"
}

compile() {
    : > "$OUT"
    if [ ! -f "$SRC" ]; then
        echo "[egress] no allow-hosts.txt mounted - DENYING EVERYTHING" >&2
        # An empty filter with FilterDefaultDeny means nothing is allowed, which
        # is the correct failure mode: a missing policy file must not silently
        # become an open proxy.
        return 0
    fi

    n=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        host=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -z "$host" ] && continue
        # A leading dot means "this domain and its subdomains". Everything else
        # is an exact host. Anchored both ends so that a rule for github.com
        # cannot be satisfied by evil-github.com.attacker.net.
        case "$host" in
            .*) printf '(^|\\.)%s$\n' "$(printf '%s' "${host#.}" | sed 's/\./\\./g')" >> "$OUT" ;;
            *)  printf '^%s$\n' "$(printf '%s' "$host" | sed 's/\./\\./g')" >> "$OUT" ;;
        esac
        n=$((n+1))
    done < "$SRC"
    echo "[egress] allowlist compiled: $n host pattern(s)"
}

render_conf
compile

# SIGHUP recompiles and reloads, so editing the allowlist does not mean
# restarting every sandbox that is proxying through this container.
trap 'compile; kill -HUP $PID 2>/dev/null || true' HUP

tinyproxy -d -c "$CONF" &
PID=$!
wait $PID

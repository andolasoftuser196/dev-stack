#!/bin/bash
# Headed Chromium on a virtual display, watchable live at https://vnc.<domain>/.
#
# "Watchable" is the requirement, not "headless". A headless run tells you a
# selector did not match; a watchable one shows you the modal that was covering
# it. For an agent verifying its own UI change, that difference is most of the
# value - and for a human deciding whether to trust the agent's account of a
# run, it is all of it.
set -euo pipefail

SCREEN="${SCREEN:-1600x1000x24}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

say() { echo "[browser] $*"; }

# Trust the stack CA so the browser reaches https://*.<domain> without an
# interstitial. An agent cannot click through a certificate warning, and a stack
# where every page starts with one is a stack where nobody uses the browser.
if [ -f /dx/ca/root.crt ]; then
    mkdir -p "$HOME/.pki/nssdb"
    if command -v certutil >/dev/null 2>&1; then
        certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n dx-local -i /dx/ca/root.crt 2>/dev/null \
            && say "installed the stack CA into the browser's NSS database" \
            || say "could not install the CA into NSS - expect certificate warnings"
    else
        say "certutil not present - expect certificate warnings on https://*.${DX_DOMAIN:-}"
    fi
fi

Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp &
sleep 1

# -shared so a second viewer does not evict the first. Two viewers (a person and
# an agent, or two people) watching one run is the normal case here, not an edge
# case, and the default behaviour of kicking the previous client is baffling when
# it happens mid-run.
x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -rfbport 5900 &

if [ -x /usr/share/novnc/utils/novnc_proxy ]; then
    /usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 7900 >/dev/null 2>&1 &
elif command -v websockify >/dev/null 2>&1; then
    websockify --web=/usr/share/novnc 7900 localhost:5900 >/dev/null 2>&1 &
else
    say "no noVNC found - port 5900 is still there for a native VNC client"
fi

say "display ${DISPLAY} at ${SCREEN}; noVNC on :7900"
say "isolated network only - this browser reaches the app under test and nothing else"

# Idle rather than exiting. Playwright specs are started against this container
# by `dx browse` and by the project's own e2e command; staying up means the
# display and the VNC bridge survive between runs, so a viewer does not have to
# reconnect for each one.
exec tail -f /dev/null

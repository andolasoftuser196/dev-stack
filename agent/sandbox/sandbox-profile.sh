# Sourced into every login shell in the sandbox. Two jobs: make ssmd usable, and
# make the boundaries visible.

# Restore the image's PATH before prepending /ssmd.
#
# This is a login shell, so /etc/profile has already run and reset PATH to a
# bare default - dropping /usr/local/go/bin, the python venv, and node's global
# bin. SSMD_IMAGE_PATH is baked into the image and survives that, because
# /etc/profile only touches PATH.
export PATH="/ssmd:${SSMD_IMAGE_PATH:-$PATH}"

# ssmd is mounted read-only at /ssmd and, run from in here, operates on this
# instance. Anything it would refuse on the host it refuses here too - the guard
# lives in ssmd, not in the shell.
alias ssmd='/ssmd/ssmd'

# Commit identity comes from the environment, never from `git config`.
#
# This matters more than it looks. /app is a linked worktree, so its .git is a
# file pointing back into the main repository's .git directory - and `git config`
# has no worktree-local scope. A `--global` write lands in this container's own
# HOME (harmless), but a `--local` one would rewrite the shared config and
# silently change the author of every commit made anywhere in that repository,
# including the human's. Environment variables cannot do that.
if [ -n "${SSMD_INSTANCE:-}" ]; then
    export GIT_AUTHOR_NAME="ssmd-agent[${SSMD_INSTANCE}]"
    export GIT_AUTHOR_EMAIL="agent+${SSMD_INSTANCE}@localhost"
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
    export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
    # Naming the sandbox in the author line is what makes an agent's commits
    # obvious in `git log` a week later, when nobody remembers which branch was
    # which.
fi

# git refuses to operate on a tree owned by another UID unless told otherwise.
# Scoped to this container's own config, and only for the one path.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0=/app

if [ -f /ssmd-ca/root.crt ]; then
    export CURL_CA_BUNDLE=/ssmd-ca/root.crt
    export SSL_CERT_FILE=/ssmd-ca/root.crt
    export NODE_EXTRA_CA_CERTS=/ssmd-ca/root.crt
fi

# Print the boundaries on entry. An agent that knows it has no route to the
# internet does not spend three turns discovering it, and a human attaching to
# debug sees immediately which instance they are in.
if [ -t 1 ]; then
    cat <<BANNER

  ssmd sandbox - instance ${SSMD_INSTANCE:-?}   (owner ${SSMD_AGENT:-?})

    /app        this instance's git worktree - the only writable path into the repo
    /ssmd         the dev-stack toolkit, read-only
    \$SSMD_APP_URL   this instance's app  (${SSMD_APP_URL:-?})
                never plain 'app' - that name is shared by every instance
    network     isolated${HTTPS_PROXY:+, outbound HTTP(S) via the allowlist proxy}${HTTPS_PROXY:-, no outbound network at all}

    ssmd verify ${SSMD_INSTANCE:-}       does the app still work?
    ssmd agent diff ${SSMD_INSTANCE:-}   what changed, and whether it can land unattended

BANNER
fi

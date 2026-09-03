# The container a coding agent runs inside.
#
# Built FROM the project's own runtime image, so the agent has exactly the
# toolchain the app runs on - the same PHP, the same node, the same go. An agent
# reasoning about a stack trace from a different minor version produces plausible
# fixes for the wrong problem.
ARG RUNTIME_IMAGE
FROM ${RUNTIME_IMAGE}

USER root

# Tools the agent actually reaches for. Deliberately short: every binary here is
# also something a prompt-injected agent could reach for, and the runtime image
# already carries the language toolchain.
RUN (command -v apt-get >/dev/null && \
      apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates jq ripgrep less procps openssh-client \
      && rm -rf /var/lib/apt/lists/*) \
    || (command -v apk >/dev/null && apk add --no-cache git curl ca-certificates jq ripgrep less procps openssh-client)

# The Claude Code CLI, when node is available in the runtime image. Not fatal if
# it is not: the sandbox is equally useful driven from the host with the worktree
# mounted, and failing the build over an optional convenience would make the
# whole feature unavailable to the PHP and Go runtimes.
RUN if command -v npm >/dev/null 2>&1; then \
        npm install -g @anthropic-ai/claude-code 2>/dev/null || \
        echo "claude-code CLI not installed - drive the sandbox from the host instead"; \
    fi

# /home/agent is a bind mount (data/agent/<slug>), so shell history, CLI config
# and anything downloaded persist across restarts of one sandbox and are
# trivially inspectable from the host afterwards.
# The image's PATH, recorded at build time.
#
# The sandbox uses a LOGIN shell on purpose - that is how the profile below
# supplies the commit identity and the CA paths - and /etc/profile resets PATH
# unconditionally, losing the language toolchain (go, the python venv, node's
# global bin). The profile restores it from here.
ENV DX_IMAGE_PATH=$PATH
ENV HOME=/home/agent \
    DX_SANDBOX=1 \
    GIT_PAGER=cat \
    PAGER=cat
RUN mkdir -p /home/agent && chmod 777 /home/agent

COPY sandbox-profile.sh /etc/profile.d/00-dx-sandbox.sh
RUN chmod 644 /etc/profile.d/00-dx-sandbox.sh

WORKDIR /app

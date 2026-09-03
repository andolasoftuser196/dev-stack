#!/usr/bin/env bash
# Shell completion for ssmd. Emitted to stdout for eval:
#   eval "$(ssmd completion bash)"      # or add to ~/.bashrc
set -euo pipefail

case "${1:-bash}" in
bash)
cat <<'BASH'
_ssmd_complete() {
    local cur prev words cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local top="up down nuke restart recreate build preflight doctor verify status urls
               describe logs sh exec run deps test lint repl db db:query db:migrate
               db:snapshot db:snapshots db:restore db:import db:drop wt agent browse
               ca-cert debug fix-perms mcp:install audit policy config completion help"

    # Slugs come from the registry, so completing `ssmd wt rm <TAB>` offers what
    # actually exists. Silent on failure: a broken completion must never be the
    # reason a shell feels broken.
    local slugs=""
    if command -v sqlite3 >/dev/null 2>&1 && [ -f config/ssmd.db ]; then
        slugs="$(sqlite3 -batch -noheader config/ssmd.db 'SELECT slug FROM instances;' 2>/dev/null | tr '\n' ' ')"
    fi
    local services="app queue scheduler proxy mysql postgres redis mailpit minio adminer cache-ui browser mcp egress"

    case "$prev" in
        ssmd)        COMPREPLY=($(compgen -W "$top" -- "$cur")); return ;;
        config)    COMPREPLY=($(compgen -W "list get set unset explain history import export hosts path" -- "$cur")); return ;;
        up)        COMPREPLY=($(compgen -W "core default tools full" -- "$cur")); return ;;
        wt)        COMPREPLY=($(compgen -W "add ls up stop rm logs sh exec verify" -- "$cur")); return ;;
        agent)     COMPREPLY=($(compgen -W "spawn ls attach run logs verify diff rm reap policy audit" -- "$cur")); return ;;
        debug)     COMPREPLY=($(compgen -W "on off status" -- "$cur")); return ;;
        completion) COMPREPLY=($(compgen -W "bash zsh" -- "$cur")); return ;;
        logs|sh|shell|exec|recreate) COMPREPLY=($(compgen -W "$services" -- "$cur")); return ;;
        rm|stop|attach|diff|verify|logs) COMPREPLY=($(compgen -W "$slugs" -- "$cur")); return ;;
        db:restore|db:import) COMPREPLY=($(compgen -f -- "$cur")); return ;;
    esac
    COMPREPLY=($(compgen -W "$top" -- "$cur"))
}
complete -F _ssmd_complete ssmd ./ssmd
BASH
;;
zsh)
cat <<'ZSH'
# zsh reuses the bash completion through bashcompinit rather than duplicating it.
# One list to keep current is the whole reason.
autoload -Uz +X compinit && compinit
autoload -Uz +X bashcompinit && bashcompinit
eval "$(ssmd completion bash)"
ZSH
;;
*) echo "unknown shell '${1}'. Valid: bash zsh" >&2; exit 1 ;;
esac

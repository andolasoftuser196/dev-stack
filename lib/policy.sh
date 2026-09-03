# lib/policy.sh - evaluate a change, or a command, against policy/.
#
# Two entry points with deliberately different consequences:
#
#   policy_check_command  used by the Claude Code PreToolUse hook. Returns 1 and
#                         a reason for a command that has no safe version. This
#                         one blocks.
#   policy_evaluate       used by `dx agent diff`. Prints a verdict. This one
#                         never blocks - a change touching a denied path is still
#                         a good change, it just needs a human.
#
# Both read plain TSV files rather than a config format, so that "why was this
# denied" is answerable with grep, and adding a rule is a one-line diff a
# reviewer can read.

POLICY_DIR="${DX_ROOT}/policy"

# Translate the documented glob syntax into a bash `case` pattern. bash's `*`
# already crosses '/', so '**' collapses to '*' - the two-star form exists in the
# file for readers who expect it, not because the matcher needs it.
_policy_glob() {
    local p="$1"
    p="${p//\*\*\//*}"
    p="${p//\/\*\*//*}"
    p="${p//\*\*/*}"
    printf '%s' "$p"
}

policy_path_denied() {  # <path> -> prints reason, returns 0 if denied
    local path="$1" glob reason pat
    [ -f "$POLICY_DIR/denied-paths.tsv" ] || return 1
    while IFS=$'\t' read -r glob reason; do
        case "$glob" in ''|\#*) continue ;; esac
        pat="$(_policy_glob "$glob")"
        # Match the full path and also any suffix of it, so a rule written for a
        # repo-root-relative path still fires when the application lives in a
        # subdirectory of a monorepo.
        case "$path" in
            $pat|*/$pat) printf '%s' "$reason"; return 0 ;;
        esac
    done < "$POLICY_DIR/denied-paths.tsv"
    return 1
}

policy_check_command() {  # <command string> -> prints reason, returns 1 if denied
    local cmd="$1" pat reason
    [ -f "$POLICY_DIR/denied-commands.tsv" ] || return 0
    while IFS=$'\t' read -r pat reason; do
        case "$pat" in ''|\#*) continue ;; esac
        if printf '%s' "$cmd" | grep -qE "$pat"; then
            printf '%s' "$reason"
            return 1
        fi
    done < "$POLICY_DIR/denied-commands.tsv"
    return 0
}

# policy.yml is the same shallow subset stack.yml uses, so it goes through the
# same compiler rather than a second, subtly-different parser. One parser to be
# wrong in one way, not two.
policy_cap() {  # <caps.max_files> etc.
    local key; key="STACK_$(printf '%s' "$1" | tr 'a-z.' 'A-Z_')"
    awk -f "$DX_ROOT/lib/yaml.awk" "$POLICY_DIR/policy.yml" 2>/dev/null \
        | sed -n "s/^${key}='\(.*\)'$/\1/p" | head -n1
}

policy_evaluate() {  # <newline-separated files> <n_files> <n_lines>
    local files="$1" nfiles="$2" nlines="$3"
    local max_files max_lines
    max_files="$(policy_cap caps.max_files)"; max_files="${max_files:-5}"
    max_lines="$(policy_cap caps.max_lines)"; max_lines="${max_lines:-200}"

    local violations=0 f reason

    echo "  Policy verdict"
    echo

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if reason="$(policy_path_denied "$f")"; then
            printf '    %sheld%s  %s\n' "$C_YLW" "$C_OFF" "$f"
            printf '           %s\n' "$reason"
            violations=$((violations+1))
        fi
    done <<< "$files"

    if [ "$nfiles" -gt "$max_files" ]; then
        printf '    %sheld%s  %d files (cap %d)\n' "$C_YLW" "$C_OFF" "$nfiles" "$max_files"
        printf '           more than one sitting of review\n'
        violations=$((violations+1))
    fi
    if [ "$nlines" -gt "$max_lines" ]; then
        printf '    %sheld%s  ~%d lines (cap %d)\n' "$C_YLW" "$C_OFF" "$nlines" "$max_lines"
        printf '           more than one sitting of review\n'
        violations=$((violations+1))
    fi

    echo
    if [ "$violations" -eq 0 ]; then
        printf '    %swithin policy%s - small, and nothing it touches is load-bearing.\n' "$C_GRN" "$C_OFF"
        echo "    Still needs a review unless gate.allow_unattended is on, which it is not by default."
    else
        printf '    %s%d reason(s) this needs a human%s.\n' "$C_YLW" "$violations" "$C_OFF"
        echo "    The change is not wrong - it is outside what should land unattended."
    fi
    audit "policy.evaluate" "files=$nfiles lines=$nlines violations=$violations"
    return 0
}

policy_show() {
    echo "Policy - ${POLICY_DIR}"
    echo
    echo "  Caps"
    printf '    max_files  %s\n' "$(policy_cap caps.max_files)"
    printf '    max_lines  %s\n' "$(policy_cap caps.max_lines)"
    echo
    echo "  Denied paths ($(grep -cvE '^(#|$)' "$POLICY_DIR/denied-paths.tsv") rules) - held for review, not blocked"
    grep -vE '^(#|$)' "$POLICY_DIR/denied-paths.tsv" | head -8 | awk -F'\t' '{printf "    %-34s %s\n", $1, $2}'
    echo "    ... (dx agent policy --all for the rest)"
    echo
    echo "  Denied commands ($(grep -cvE '^(#|$)' "$POLICY_DIR/denied-commands.tsv") rules) - blocked outright"
    grep -vE '^(#|$)' "$POLICY_DIR/denied-commands.tsv" | head -8 | awk -F'\t' '{printf "    %-44s %s\n", substr($1,1,44), substr($2,1,60)}'
    echo
    echo "  Egress allowlist ($(grep -cvE '^(#|$)' "$POLICY_DIR/allow-hosts.txt") hosts)"
    grep -vE '^(#|$)' "$POLICY_DIR/allow-hosts.txt" | sed 's/^/    /' | head -12
}

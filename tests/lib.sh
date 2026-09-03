# tests/lib.sh - the test harness.
#
# Hand-rolled rather than bats, for the same reason ssmd has no runtime
# dependencies: the tests have to run on the machine where something is already
# broken, and "install bats first" is a poor answer there. It is ~120 lines and
# it does the four things a shell test harness actually needs - compare, report,
# isolate, and exit non-zero.
#
# Each test file is a standalone executable that sources this, runs assertions,
# and ends with t_summary. The runner (tests/run) tallies the machine-readable
# summary line each file prints.

set -uo pipefail          # NOT -e: an assertion that fails must be recorded, not fatal

T_PASS=0; T_FAIL=0; T_SKIP=0
T_NAME="$(basename "${BASH_SOURCE[1]:-tests}" .sh)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _D=$'\033[2m'; _O=$'\033[0m'
else
    _G=''; _R=''; _Y=''; _D=''; _O=''
fi

t_ok()   { T_PASS=$((T_PASS+1)); printf '  %sok%s   %s\n' "$_G" "$_O" "$1"; }
t_fail() {
    T_FAIL=$((T_FAIL+1))
    printf '  %sFAIL%s %s\n' "$_R" "$_O" "$1"
    [ $# -gt 1 ] && printf '%s' "$2" | sed "s/^/       ${_D}/;s/\$/${_O}/"
    return 0
}
t_skip() { T_SKIP=$((T_SKIP+1)); printf '  %sskip%s %s%s\n' "$_Y" "$_O" "$1" "${2:+  ($2)}"; }

assert_eq() {  # <expected> <actual> <description>
    if [ "$1" = "$2" ]; then t_ok "$3"
    else t_fail "$3" "expected: $(printf '%q' "$1")
actual:   $(printf '%q' "$2")
"; fi
}

assert_ne() {
    if [ "$1" != "$2" ]; then t_ok "$3"
    else t_fail "$3" "both sides were: $(printf '%q' "$1")
"; fi
}

assert_contains() {  # <haystack> <needle> <description>
    case "$1" in
        *"$2"*) t_ok "$3" ;;
        *) t_fail "$3" "looked for: $2
in:
$(printf '%s' "$1" | head -20 | sed 's/^/  | /')
" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) t_fail "$3" "unexpectedly found: $2
in:
$(printf '%s' "$1" | head -20 | sed 's/^/  | /')
" ;;
        *) t_ok "$3" ;;
    esac
}

assert_match() {  # <string> <ERE> <description>
    if printf '%s' "$1" | grep -qE "$2"; then t_ok "$3"
    else t_fail "$3" "did not match: $2
in:
$(printf '%s' "$1" | head -20 | sed 's/^/  | /')
"; fi
}

# Run a command, expect success. Output is captured and shown only on failure -
# a passing test that prints half a screen makes the failing one invisible.
assert_ok() {  # <description> <cmd...>
    local desc="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then t_ok "$desc"
    else t_fail "$desc" "exit $rc from: $*
$(printf '%s' "$out" | head -20 | sed 's/^/  | /')
"; fi
}

assert_fail() {  # <description> <cmd...> - expect NON-zero
    local desc="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then t_ok "$desc"
    else t_fail "$desc" "expected failure but it succeeded: $*
$(printf '%s' "$out" | head -10 | sed 's/^/  | /')
"; fi
}

assert_file() { [ -f "$1" ] && t_ok "$2" || t_fail "$2" "no such file: $1
"; }
assert_no_file() { [ ! -e "$1" ] && t_ok "$2" || t_fail "$2" "file exists but should not: $1
"; }

t_section() { printf '\n%s── %s%s\n' "$_D" "$1" "$_O"; }

t_summary() {
    printf '\n#SUMMARY %d %d %d\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
    [ "$T_FAIL" -eq 0 ]
}

# ── fixtures ────────────────────────────────────────────────────────────────

TEST_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export TEST_ROOT

# A throwaway copy of the toolkit with its own config database.
#
# A copy rather than the real directory: these tests seed databases, write
# routes and set config, and doing that in the developer's own dev-stack would
# be both destructive and a source of test pollution nobody would diagnose
# quickly. data/ and the existing database are excluded so every sandbox starts
# from the seeds alone.
mk_sandbox() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/ssmdtest.XXXXXX")"
    tar -C "$TEST_ROOT" \
        --exclude=./data --exclude=./.git --exclude=./tests \
        --exclude=./config/ssmd.db --exclude=./config/ssmd.db-wal --exclude=./config/ssmd.db-shm \
        --exclude=./.stack.env --exclude=./scaffold/.venv --exclude=__pycache__ \
        -cf - . 2>/dev/null | tar -C "$d" -xf -
    printf '%s' "$d"
}

# Source the config layer against a sandbox. Returns with SSMD_ROOT/SSMD_DB_PATH set
# and the configuration resolved, exactly as ssmd would have them.
load_sandbox() {  # <sandbox-dir> [host-profile]
    export SSMD_ROOT="$1"
    cd "$SSMD_ROOT" || return 1
    export SSMD_HOST="${2:-local}"
    export SSMD_ACTOR="test"
    # shellcheck disable=SC1090
    . "$SSMD_ROOT/lib/core.sh"; . "$SSMD_ROOT/lib/sqlite.sh"; . "$SSMD_ROOT/lib/config.sh"
    set +e                        # core.sh turns on errexit; assertions need it off
    load_config
    load_runtime          # defines the rt_* functions, exactly as ssmd does
    for m in db instance worktree agent policy doctor; do . "$SSMD_ROOT/lib/$m.sh"; done
    set +e
}

rm_sandbox() { [ -n "${1:-}" ] && [ -d "$1" ] && rm -rf "$1"; }

# A file's content with comments removed.
#
# Almost every "the code must not contain X" assertion in this suite was written
# against a file whose comments *explain why it must not contain X*. Matching the
# explanation and reporting a failure happened four times before this helper
# existed; do not grep a source file for a forbidden token without it.
#
# Handles the three comment syntaxes in this repository: #, //, and <!-- -->.
code_only() {
    case "$1" in
        *.xml|*.html)
            perl -0pe 's/<!--.*?-->//gs' "$1" 2>/dev/null || sed '/<!--/,/-->/d' "$1" ;;
        *.js|*.ts|*.go|*.php|*.java)
            sed -e 's|//.*$||' -e '/^\s*\/\*/,/\*\//d' "$1" ;;
        *)
            grep -vE '^[[:space:]]*#' "$1" ;;
    esac
}

have_docker() { command -v docker >/dev/null 2>&1; }
have_docker_daemon() { have_docker && docker info >/dev/null 2>&1; }

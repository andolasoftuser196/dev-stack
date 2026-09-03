#!/usr/bin/env bash
# Every runtime module must satisfy runtimes/_contract.md. A module that is
# missing a function fails at the moment someone runs that verb, which is
# always inconvenient; this catches it at commit time instead.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

REQUIRED_FN="rt_display_name rt_verbs rt_deps_present rt_deps_install rt_migrate
             rt_test rt_lint rt_repl rt_dispatch rt_exec"
REQUIRED_FILE="Dockerfile entrypoint.sh commands.sh serve.conf"

KINDS="$(cd runtimes && ls -d */ | tr -d /)"
assert_contains "$KINDS" "frankenphp" "frankenphp module present"
assert_contains "$KINDS" "node" "node module present"
assert_contains "$KINDS" "python" "python module present"
assert_contains "$KINDS" "go" "go module present"

for kind in $KINDS; do
    t_section "runtime: $kind"

    for f in $REQUIRED_FILE; do
        assert_file "runtimes/$kind/$f" "has $f"
    done
    assert_ok "entrypoint.sh is executable" test -x "runtimes/$kind/entrypoint.sh"
    assert_ok "commands.sh is valid bash" bash -n "runtimes/$kind/commands.sh"
    assert_ok "entrypoint.sh is valid shell" sh -n "runtimes/$kind/entrypoint.sh"

    # Load the module in a subshell so one runtime's definitions cannot leak
    # into the next one's assertions.
    ( config_set runtime.kind "$kind" stack >/dev/null 2>&1
      load_sandbox "$SB" local >/dev/null 2>&1
      miss=""
      for fn in $REQUIRED_FN; do
          declare -F "$fn" >/dev/null || miss="$miss $fn"
      done
      [ -z "$miss" ] || { echo "missing:$miss"; exit 1; }
      [ -n "$(rt_display_name)" ] || { echo "rt_display_name is empty"; exit 1; }
      [ -n "$(rt_verbs)" ]        || { echo "rt_verbs is empty"; exit 1; }
      # An unknown verb must return 1 so dx can print its own error rather than
      # the module swallowing it.
      rt_dispatch definitely-not-a-verb 2>/dev/null && { echo "rt_dispatch accepted a bogus verb"; exit 1; }
      exit 0 )
    rc=$?
    [ $rc -eq 0 ] && t_ok "implements the full rt_* contract" \
                  || t_fail "implements the full rt_* contract"

    # The base image must be an argument, never a literal tag: a tag here is a
    # second place to bump a version, and the two drift.
    code_only "runtimes/$kind/Dockerfile" | grep -qE '^ARG BASE_IMAGE' \
        && t_ok "Dockerfile takes BASE_IMAGE as an argument" \
        || t_fail "Dockerfile takes BASE_IMAGE as an argument"
    code_only "runtimes/$kind/Dockerfile" | grep -qE '^FROM [a-z]' \
        && t_fail "Dockerfile has no hardcoded FROM" || t_ok "Dockerfile has no hardcoded FROM"

    # `@latest` in a Dockerfile is `:latest` on an image tag wearing a hat: the
    # tool resolves to whatever released this morning, which may require a newer
    # language runtime than the image has, and the build then fails on a machine
    # where nothing changed.
    code_only "runtimes/$kind/Dockerfile" | grep -qE '@latest|:latest' \
        && t_fail "Dockerfile pins every tool it installs" "found @latest or :latest
" \
        || t_ok "Dockerfile pins every tool it installs"

    # healthz answered by the web server is the invariant everything else rests on.
    grep -q 'DX_HEALTHZ' "runtimes/$kind/serve.conf" \
        && t_ok "serve.conf answers \$DX_HEALTHZ itself" \
        || t_fail "serve.conf answers \$DX_HEALTHZ itself"
    grep -q 'respond "ok" 200' "runtimes/$kind/serve.conf" \
        && t_ok "and answers it with a literal 200, not by proxying" \
        || t_fail "and answers it with a literal 200, not by proxying"

    # Every runtime must handle all four roles, or an instance that only needs a
    # shell cannot start.
    for role in serve queue scheduler idle; do
        grep -qE "^[[:space:]]*$role\)" "runtimes/$kind/entrypoint.sh" \
            && t_ok "entrypoint handles role '$role'" \
            || t_fail "entrypoint handles role '$role'"
    done

    # The image must not bake in a UID; containers run as the invoking user.
    code_only "runtimes/$kind/Dockerfile" | grep -qE '^USER [0-9]' \
        && t_fail "Dockerfile bakes in no UID" || t_ok "Dockerfile bakes in no UID"

    # Caches must land on the shared bind mount, not in the image or the repo.
    grep -q 'HOME=/dx/cache' "runtimes/$kind/Dockerfile" \
        && t_ok "HOME points at the shared cache" || t_fail "HOME points at the shared cache"
done

t_section "project commands run through the runtime, not raw docker exec"
# `docker exec` starts a process that never ran the entrypoint, so the python
# venv is not active — and a hook then fails with ModuleNotFoundError for a
# package it just watched get installed.
for pat in 'rt_exec app "\$h"' 'rt_exec app "\$\*"' 'rt_exec "\$local_svc"'; do
    grep -qF "$(printf '%s' "$pat" | sed 's/\\//g')" dx \
        && t_ok "dx uses rt_exec: $(printf '%s' "$pat" | sed 's/\\//g')" \
        || t_fail "dx uses rt_exec: $(printf '%s' "$pat" | sed 's/\\//g')"
done
code_only lib/worktree.sh | grep -q 'rt_exec app' \
    && t_ok "instances use rt_exec too" || t_fail "instances use rt_exec too"

t_section "no non-interactive path uses a login shell"
# /etc/profile resets PATH unconditionally on Debian, dropping whatever the
# image added - /usr/local/go/bin, the python venv, node's global bin. The
# symptom is `go: not found` in a container that plainly has go in it.
#
# `dx sh` is exempt: it is interactive, and a profile banner is the point there.
# The agent sandbox is exempt too, and restores PATH from DX_IMAGE_PATH.
for f in dx lib/worktree.sh runtimes/*/commands.sh runtimes/*/entrypoint.sh; do
    hits="$(code_only "$f" | grep -n 'sh -lc' || true)"
    [ -z "$hits" ] && t_ok "$f runs commands in a plain shell" \
                   || t_fail "$f runs commands in a plain shell" "$hits
"
done
grep -q 'DX_IMAGE_PATH' agent/sandbox/Dockerfile \
    && t_ok "the sandbox records the image PATH for its login shell" \
    || t_fail "the sandbox records the image PATH for its login shell"
grep -q 'DX_IMAGE_PATH' agent/sandbox/sandbox-profile.sh \
    && t_ok "and its profile restores it" || t_fail "and its profile restores it"

t_section "a missing lockfile is handled, not left to the package manager"
# `npm ci` without a lockfile emits its own usage text, which says nothing about
# the actual problem.
grep -q '_has_lockfile' runtimes/node/commands.sh \
    && t_ok "node checks for a lockfile before a frozen install" \
    || t_fail "node checks for a lockfile before a frozen install"
grep -q 'composer.lock' runtimes/frankenphp/commands.sh \
    && t_ok "php checks for a lockfile before installing" \
    || t_fail "php checks for a lockfile before installing"

t_section "config knows every runtime the directory provides"
load_sandbox "$SB" local
for kind in $KINDS; do
    K="$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')"
    assert_ok "runtime_images.$kind is configured" _cfg "RUNTIME_IMAGES_$K"
    assert_ok "app_ports.$kind is configured"     _cfg "APP_PORTS_$K"
    assert_contains "$(_cfg "RUNTIME_IMAGES_$K")" "{version}" \
        "runtime_images.$kind is a template"
done

t_summary

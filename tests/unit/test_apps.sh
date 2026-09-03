#!/usr/bin/env bash
# demo-apps/ - the demo application per runtime.
#
# These must stay in step with the examples that point at them and with the
# contract in demo-apps/README.md, or `dx up` on a fresh clone stops working - which
# is the one thing they exist to guarantee.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

APPS="laravel cakephp symfony php-plain next nest express vite django fastapi flask python-plain go"

t_section "one app per allowed runtime, and no orphans"
for a in $APPS; do
    assert_ok "demo-apps/$a exists" test -d "demo-apps/$a"
done
extra="$(cd demo-apps && ls -d */ 2>/dev/null | tr -d / | grep -vxF "$(printf '%s\n' $APPS)" || true)"
assert_eq "" "$extra" "no app directory is undocumented"

t_section "every example points at an app that exists"
for f in examples/runtimes/*.stack.yml; do
    root="$(awk -f lib/yaml.awk "$f" | sed -n "s/^STACK_REPO_ROOT='\(.*\)'$/\1/p")"
    case "$root" in
        demo-apps/*) assert_ok "$(basename "$f" .stack.yml) -> $root" test -d "$root" ;;
        *) t_fail "$(basename "$f" .stack.yml) points at a demo app" "root=$root
" ;;
    esac
done

t_section "every app is reachable from exactly one example"
for a in $APPS; do
    n="$(grep -l "root: demo-apps/$a\$" examples/runtimes/*.stack.yml 2>/dev/null | wc -l)"
    assert_eq "1" "$n" "demo-apps/$a is referenced by one example"
done

t_section "the status contract"
# One shape across thirteen apps is what lets a single integration test boot all
# of them and assert the same things.
#
# Keys are matched as `key=` OR as a quoted 'key' - some apps write the line
# literally, others build it from a label. Both are fine; what matters is that
# the key is produced at all.
reports() {  # reports <app> <key>
    grep -rqE "$2=|['\"]$2['\"]" "demo-apps/$1" 2>/dev/null
}
for a in $APPS; do
    grep -rqF 'dx demo app' "demo-apps/$a" 2>/dev/null \
        && t_ok "demo-apps/$a renders the agreed first line" \
        || t_fail "demo-apps/$a renders the agreed first line"
    missing=""
    for k in runtime instance database cache; do
        reports "$a" "$k" || missing="$missing $k"
    done
    [ -z "$missing" ] && t_ok "demo-apps/$a reports every status key" \
                      || t_fail "demo-apps/$a reports every status key" "missing:$missing
"
done

t_section "no app serves its own /healthz"
# Caddy answers it in every runtime, and it has to keep answering while the
# application is broken. An app-level healthz defeats the entire point.
#
# A ROUTE, not the word: every one of these apps has a comment explaining why it
# does not define one, and matching the word would flag all of them.
healthz_route() {  # a route registration mentioning healthz, in any of the four ecosystems
    grep -rqE "(Route::[a-z]+|@app\.[a-z]+|@Get|app\.[a-z]+|HandleFunc|path|connect|urlpatterns)[^\n]*healthz" \
        "demo-apps/$1" 2>/dev/null
}
for a in $APPS; do
    healthz_route "$a" \
        && t_fail "demo-apps/$a does not define a healthz route" "found a route registration
" \
        || t_ok "demo-apps/$a leaves healthz to the web server"
done

t_section "every app binds 0.0.0.0, never localhost"
# Bound to loopback inside a container the process is unreachable from Caddy,
# and the symptom is a 502 with an empty application log.
for a in express nest vite python-plain go; do
    grep -rqE "0\.0\.0\.0|ListenAndServe" "demo-apps/$a" 2>/dev/null \
        && t_ok "demo-apps/$a binds all interfaces" || t_fail "demo-apps/$a binds all interfaces"
    if grep -rqE "listen\(.*127\.0\.0\.1|host: *'127\.0\.0\.1'" "demo-apps/$a" 2>/dev/null; then
        t_fail "demo-apps/$a does not bind loopback"
    else t_ok "demo-apps/$a does not bind loopback"; fi
done

t_section "no test configuration names a database"
# A suite that names its own database eventually truncates the wrong one. dx
# supplies a disposable name in the environment instead.
# code_only strips comments first: every one of these files explains at length
# why it does NOT name a database, and matching the explanation would flag all
# of them. See the note on code_only in tests/lib.sh.
for f in $(find apps -name 'phpunit.xml' -o -name 'pytest.ini' -o -name 'pyproject.toml' 2>/dev/null); do
    if code_only "$f" | grep -qiE 'DB_DATABASE|DATABASE_URL|db_name'; then
        t_fail "$f names no database" "it does - dx supplies a disposable one
"
    else t_ok "$(basename "$(dirname "$f")")/$(basename "$f") names no database"; fi
done

t_section "every app asserts the disposable-database guard in its own suite"
for a in $APPS; do
    if [ "$a" = vite ]; then t_skip "demo-apps/vite" "no database"; continue; fi
    grep -rqE '_test\|_sandbox|\(_test\|_sandbox\)' "demo-apps/$a" 2>/dev/null \
        && t_ok "demo-apps/$a checks it runs against a disposable database" \
        || t_fail "demo-apps/$a checks it runs against a disposable database"
done

t_section "manifests"
for a in laravel cakephp symfony php-plain; do
    assert_file "demo-apps/$a/composer.json" "demo-apps/$a has composer.json"
    assert_ok "demo-apps/$a/composer.json is valid JSON" python3 -c "import json;json.load(open('demo-apps/$a/composer.json'))"
done
for a in next nest express vite; do
    assert_file "demo-apps/$a/package.json" "demo-apps/$a has package.json"
    assert_ok "demo-apps/$a/package.json is valid JSON" python3 -c "import json;json.load(open('demo-apps/$a/package.json'))"
done
for a in django fastapi; do assert_file "demo-apps/$a/pyproject.toml" "demo-apps/$a has pyproject.toml"; done
for a in flask python-plain; do assert_file "demo-apps/$a/requirements.txt" "demo-apps/$a has requirements.txt"; done
assert_file "demo-apps/go/go.mod" "demo-apps/go has go.mod"

t_section "syntax"
if command -v php >/dev/null 2>&1; then
    bad=0
    for f in $(find apps -name '*.php'); do php -l "$f" >/dev/null 2>&1 || { t_fail "php -l $f"; bad=1; }; done
    [ $bad = 0 ] && t_ok "every PHP file parses ($(find apps -name '*.php' | wc -l) files)"
else t_skip "PHP syntax" "no php on the host"; fi

if command -v node >/dev/null 2>&1; then
    bad=0
    for f in $(find apps -name '*.js' -not -path '*/node_modules/*' -not -name 'main.js' -not -path '*/app/*'); do
        node --check "$f" >/dev/null 2>&1 || { t_fail "node --check $f"; bad=1; }
    done
    [ $bad = 0 ] && t_ok "every CommonJS file parses"
else t_skip "JS syntax" "no node on the host"; fi

bad=0
for f in $(find apps -name '*.py'); do
    python3 -m py_compile "$f" 2>/dev/null || { t_fail "py_compile $f"; bad=1; }
done
[ $bad = 0 ] && t_ok "every Python file compiles ($(find apps -name '*.py' | wc -l) files)"
find apps -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null

if command -v gofmt >/dev/null 2>&1; then
    out="$(gofmt -l demo-apps/go 2>&1)"
    assert_eq "" "$out" "every Go file is gofmt-clean"
else t_skip "Go formatting" "no gofmt on the host"; fi

t_section "the demo apps are not presented as starter templates"
assert_contains "$(cat demo-apps/README.md)" "not starter templates" \
    "the README says plainly what they are for"

t_summary

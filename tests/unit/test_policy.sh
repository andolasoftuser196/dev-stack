#!/usr/bin/env bash
# lib/policy.sh - the command guard and the review gate.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

denied() { ! policy_check_command "$1" >/dev/null 2>&1; }

t_section "commands with no safe version are refused"
while IFS='|' read -r cmd why; do
    [ -z "$cmd" ] && continue
    denied "$cmd" && t_ok "denied: $cmd" || t_fail "denied: $cmd" "$why
"
done <<'CASES'
docker compose up -d|raw compose starts a different stack
docker-compose up|compose v1 is unsupported
php artisan test|the bare runner can truncate the dev database
php artisan test --filter=X|with arguments too
vendor/bin/phpunit|the bare runner
phpunit --testsuite unit|on PATH too
pytest tests/|same rule for python
go test ./...|same rule for go
composer update|rewrites the lockfile
composer require foo/bar|rewrites the lockfile
npm install lodash|rewrites the lockfile
pnpm add left-pad|rewrites the lockfile
go mod tidy|rewrites go.mod and go.sum
mysql -e 'DROP DATABASE x'|no dropping from a shell
psql -c 'TRUNCATE TABLE users'|no truncating from a shell
git reset --hard HEAD~1|discards uncommitted work
git push --force origin main|discards someone else's work
CASES

t_section "ordinary work is allowed"
for cmd in "ls -la" "git status" "git commit -m x" "npm ci" "grep -r foo ." \
           "cat composer.json" "docker ps" "php -v" "go build ./..." \
           "git push origin feature" "git push --force-with-lease origin feature"; do
    denied "$cmd" && t_fail "allowed: $cmd" "was denied
" || t_ok "allowed: $cmd"
done

t_section "every denial names an alternative"
missing=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    reason="${line#*$(printf '\t')}"
    [ -n "$reason" ] || missing=$((missing+1))
done < policy/denied-commands.tsv
assert_eq "0" "$missing" "no denied-command rule is missing its reason"

t_section "path globs"
# ** crosses separators, * does not - getting that wrong in the permissive
# direction produces denials nobody can explain.
for p in ".env" "app/.env" "deep/nested/.env" "composer.lock" \
         "database/migrations/2024_x.php" "src/Database/Migrations/M.php" \
         ".github/workflows/ci.yml" "config/app.php" "app/Http/Middleware/Auth.php"; do
    policy_path_denied "$p" >/dev/null \
        && t_ok "held: $p" || t_fail "held: $p" "not matched by any rule
"
done
for p in "src/Service.php" "README.md" "app/Models/User.php" "tests/Unit/FooTest.php" \
         "resources/views/home.blade.php"; do
    policy_path_denied "$p" >/dev/null \
        && t_fail "not held: $p" "unexpectedly matched
" || t_ok "not held: $p"
done

t_section "every denied path names a reason"
missing=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    reason="${line#*$(printf '\t')}"
    [ -n "$reason" ] && [ "$reason" != "$line" ] || missing=$((missing+1))
done < policy/denied-paths.tsv
assert_eq "0" "$missing" "no denied-path rule is missing its reason"

t_section "the review gate holds, it does not block"
out="$(policy_evaluate "src/Foo.php" 1 10)"
assert_contains "$out" "within policy" "a small, safe change is within policy"
assert_ok "and evaluate still exits zero" policy_evaluate "src/Foo.php" 1 10

out="$(policy_evaluate "composer.lock" 1 2)"
assert_contains "$out" "held" "a lockfile change is held"
assert_contains "$out" "re-resolve" "and the reason is printed"
assert_ok "a held change still exits zero - the gate never blocks" \
    policy_evaluate "composer.lock" 1 2

t_section "size caps come from config"
mf="$(policy_cap caps.max_files)"; ml="$(policy_cap caps.max_lines)"
assert_eq "5" "$mf" "max_files read from policy.yml"
assert_eq "200" "$ml" "max_lines read from policy.yml"
assert_contains "$(policy_evaluate "a.php" $((mf+1)) 10)" "files (cap $mf)" "over the file cap is held"
assert_contains "$(policy_evaluate "a.php" 1 $((ml+1)))" "lines (cap $ml)" "over the line cap is held"
assert_not_contains "$(policy_evaluate "a.php" "$mf" "$ml")" "held" "exactly at the cap is not held"

t_section "a malformed rule is skipped, not fatal"
cp policy/denied-commands.tsv /tmp/dcbak.$$
printf '[unclosed\tbroken rule\n' >> policy/denied-commands.tsv
assert_ok "a bad regex does not break the guard" policy_check_command "ls"
denied "docker compose up" && t_ok "and the other rules still fire" \
                           || t_fail "and the other rules still fire"
cp /tmp/dcbak.$$ policy/denied-commands.tsv; rm -f /tmp/dcbak.$$

t_summary

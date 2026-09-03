#!/usr/bin/env bash
# lib/db.sh - the pattern guards. These are the rules standing between a typo
# and a lost database, so they are tested without a database: pure predicates.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
SB="$(mk_sandbox)"; trap 'rm_sandbox "$SB"' EXIT
load_sandbox "$SB"

t_section "disposable patterns"
for n in app_dev_test foo_sandbox app_dev_feature_x wt_thing agentrun_42; do
    db_matches_patterns "$n" DATABASE_SAFETY_DISPOSABLE \
        && t_ok "disposable: $n" || t_fail "disposable: $n"
done
for n in app_dev production customers app_prod testing_data mysql; do
    db_matches_patterns "$n" DATABASE_SAFETY_DISPOSABLE \
        && t_fail "NOT disposable: $n" "matched a disposable pattern" || t_ok "NOT disposable: $n"
done

t_section "{db} expands to this project's database, not a literal"
assert_contains "$(db_disposable_patterns)" "app_dev_*" "{db} expanded"
assert_not_contains "$(db_disposable_patterns)" "{db}" "no placeholder left"
# Renaming the database must move the pattern with it, or dx would still be
# willing to drop the old project's instance databases.
config_set database.name other_dev stack >/dev/null; load_sandbox "$SB" local
db_matches_patterns other_dev_x DATABASE_SAFETY_DISPOSABLE \
    && t_ok "renaming the database moves the pattern" || t_fail "renaming the database moves the pattern"
db_matches_patterns app_dev_x DATABASE_SAFETY_DISPOSABLE \
    && t_fail "and the old prefix stops matching" || t_ok "and the old prefix stops matching"
config_set database.name app_dev stack >/dev/null; load_sandbox "$SB" local

t_section "test patterns are narrower than disposable"
for n in app_dev_test foo_sandbox; do
    db_matches_patterns "$n" DATABASE_SAFETY_TEST_PATTERN \
        && t_ok "test-safe: $n" || t_fail "test-safe: $n"
done
for n in app_dev app_dev_feature_x wt_thing; do
    db_matches_patterns "$n" DATABASE_SAFETY_TEST_PATTERN \
        && t_fail "NOT test-safe: $n" "a suite could truncate this" || t_ok "NOT test-safe: $n"
done

t_section "the computed test database is itself test-safe"
td="${DB_NAME}$(_cfg DATABASE_SAFETY_TEST_SUFFIX)"
assert_eq "app_dev_test" "$td" "the suffix is applied"
db_matches_patterns "$td" DATABASE_SAFETY_TEST_PATTERN \
    && t_ok "and the result passes the guard" || t_fail "and the result passes the guard"

t_section "a bad test suffix is caught by the guard, not shipped"
# Someone setting an empty suffix would point the suite at the development
# database. The pattern check is what stops it.
config_set database_safety.test_suffix "" stack >/dev/null; load_sandbox "$SB" local
bad="${DB_NAME}$(_cfgd DATABASE_SAFETY_TEST_SUFFIX '')"
db_matches_patterns "$bad" DATABASE_SAFETY_TEST_PATTERN \
    && t_fail "an empty suffix must not pass" "would target $bad" \
    || t_ok "an empty suffix is refused by the pattern guard"
config_set database_safety.test_suffix _test stack >/dev/null; load_sandbox "$SB" local

t_section "every runtime enforces the same rule"
# The check used to be copy-pasted into four commands.sh files with three
# different pattern sets. It is one function now; assert nobody re-inlines it.
for f in runtimes/*/commands.sh; do
    grep -q 'db_matches_patterns "$test_db" DATABASE_SAFETY_TEST_PATTERN' "$f" \
        && t_ok "$(basename "$(dirname "$f")") uses the shared guard" \
        || t_fail "$(basename "$(dirname "$f")") uses the shared guard"
    grep -qE 'case "\$test_db" in \*_test' "$f" \
        && t_fail "$(basename "$(dirname "$f")") has no re-inlined pattern" || \
        t_ok "$(basename "$(dirname "$f")") has no re-inlined pattern"
done

t_section "snapshot-before-destroy is configurable but on"
assert_eq "true" "$(config_get database_safety.snapshot_before_destroy)" "on by default"

t_section "no database configured"
config_set services.database none stack >/dev/null; load_sandbox "$SB" local
assert_fail "db_require refuses when there is no database" db_require
assert_contains "$(db_require 2>&1)" "no database" "and says so plainly"

t_summary

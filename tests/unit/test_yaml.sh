#!/usr/bin/env bash
# lib/yaml.awk - the seed reader. Pure function, no fixtures needed.
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
AWK="awk -f $TEST_ROOT/lib/yaml.awk"
D="awk -v mode=dotted -f $TEST_ROOT/lib/yaml.awk"
y() { printf '%s\n' "$1" > /tmp/ssmdy.$$.yml; }
cleanup() { rm -f /tmp/ssmdy.$$.yml; }
trap cleanup EXIT

t_section "shell mode"
y 'name: app'
assert_eq "STACK_NAME='app'" "$($AWK /tmp/ssmdy.$$.yml)" "scalar"

y 'a:
  b:
    c: deep'
assert_eq "STACK_A_B_C='deep'" "$($AWK /tmp/ssmdy.$$.yml)" "three levels nest"

y 'k: [a, b, c]'
assert_eq "STACK_K='a
b
c'" "$($AWK /tmp/ssmdy.$$.yml)" "inline list joins on newline"

y 'k:
  - one
  - two'
assert_eq "STACK_K='one
two'" "$($AWK /tmp/ssmdy.$$.yml)" "block list"

y 'k: []'
assert_eq "STACK_K=''" "$($AWK /tmp/ssmdy.$$.yml)" "empty inline list is emitted, not skipped"

y 'v: "8.3"'
assert_eq "STACK_V='8.3'" "$($AWK /tmp/ssmdy.$$.yml)" "quotes stripped"

y "p: 'a b'"
assert_eq "STACK_P='a b'" "$($AWK /tmp/ssmdy.$$.yml)" "single quotes stripped"

y "q: it's"
assert_eq "STACK_Q='it'\\''s'" "$($AWK /tmp/ssmdy.$$.yml)" "apostrophe is shell-escaped"

y 'a: 1   # trailing comment
# whole-line comment
b: 2'
assert_eq "STACK_A='1'
STACK_B='2'" "$($AWK /tmp/ssmdy.$$.yml)" "comments stripped"

y 'u: https://x.test/#frag'
assert_eq "STACK_U='https://x.test/#frag'" "$($AWK /tmp/ssmdy.$$.yml)" \
    "a # with no preceding space is not a comment"

y 'p: "a # b"'
assert_eq "STACK_P='a # b'" "$($AWK /tmp/ssmdy.$$.yml)" "# inside quotes survives"

y 'hyphen-key: v'
assert_eq "STACK_HYPHEN_KEY='v'" "$($AWK /tmp/ssmdy.$$.yml)" "hyphens become underscores"

y 'parent:
  child: v
after: w'
assert_contains "$($AWK /tmp/ssmdy.$$.yml)" "STACK_AFTER='w'" "dedent resumes the top level"
assert_not_contains "$($AWK /tmp/ssmdy.$$.yml)" "STACK_PARENT=" "a pure parent emits nothing"

t_section "dotted mode"
y 'a:
  b: v'
assert_eq "a.b${SSMD_TAB:-$(printf '\t')}v" "$($D /tmp/ssmdy.$$.yml)" "dotted key"

y 'k:
  - one
  - two'
assert_eq "k$(printf '\t')one\\ntwo" "$($D /tmp/ssmdy.$$.yml)" "list newlines escaped to keep one row per line"

t_section "malformed input warns rather than silently mis-parsing"
y 'a:
	b: 1'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'tab indentation' "tab indent warns"

y 'a:
   b: 1'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'odd indentation' "odd indent warns"

y 'not a key at all'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'not a key' "non-key warns"

y 'a:
      b: 1'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'indentation jumps' "over-indent warns"

y '- orphan'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'list item with no parent' "orphan list item warns"

y 'k:
  - a: 1'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'maps inside lists' "map-in-list warns"

y 'a: 1
a: 2'
assert_match "$($AWK /tmp/ssmdy.$$.yml 2>&1 >/dev/null)" 'duplicate key' "duplicate key warns"
assert_contains "$($AWK /tmp/ssmdy.$$.yml 2>/dev/null)" "STACK_A='2'" "later duplicate wins"

t_section "the real seed files"
for f in config/defaults.yml config/stack.yml config/hosts.yml; do
    w="$($AWK "$TEST_ROOT/$f" 2>&1 >/dev/null | wc -l)"
    assert_eq "0" "$w" "$f parses with no warnings"
done
for f in "$TEST_ROOT"/examples/*/*.stack.yml; do
    w="$($AWK "$f" 2>&1 >/dev/null | wc -l)"
    [ "$w" = "0" ] || t_fail "example $(basename "$f") parses cleanly" "$w warning(s)"
done
t_ok "all $(ls "$TEST_ROOT"/examples/*/*.stack.yml | wc -l) examples parse with no warnings"

t_summary

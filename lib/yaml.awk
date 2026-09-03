# lib/yaml.awk - read the config seed files under config/.
#
# Why not yq, python or ruby: `ssmd` is the thing you reach for when the stack is
# already broken, and every runtime dependency is one more way for it to be
# broken too. The driver has to keep working on a box with nothing but bash,
# docker and a shell - which is exactly the box you are on when it matters.
#
# Two consumers: `ssmd config import` (mode=dotted) turns a seed file into rows for
# the SQLite config store, and the resolver (mode=shell) turns the resolved
# result back into a sourceable cache. One traversal, two renderings.
#
# This is NOT a YAML parser. It reads the fixed, shallow subset the seed files
# are documented to use, and nothing else:
#
#   key: value                  ->  STACK_KEY='value'
#   parent:                         STACK_PARENT_CHILD='value'
#     child: value
#   key: [a, b, c]              ->  STACK_KEY='a\nb\nc'
#   key:                        ->  STACK_KEY='a\nb'
#     - a
#     - b
#
# Lists join on newline rather than space so that list items containing spaces
# (every hooks: entry does) survive. Bash's default IFS splits on newline too, so
# `for x in $STACK_ROUTES_OPTIONAL` still iterates correctly.
#
# Anything the subset does not cover - anchors, multi-line scalars, nested lists,
# maps inside lists - is reported on stderr and skipped, so a typo shows up as a
# loud warning rather than a value that silently becomes empty.

function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s
}

# Strip a trailing comment, but only when '#' is preceded by whitespace and is
# not inside a quoted scalar. "app#1" and "pw: 'a # b'" both survive.
function strip_comment(s,   i, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = "" ; continue }
        if (c == "\"" || c == "'") { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i-1, 1) ~ /[ \t]/)) return substr(s, 1, i-1)
    }
    return s
}

function unquote(s) {
    s = trim(s)
    if (s ~ /^".*"$/ || s ~ /^'.*'$/) s = substr(s, 2, length(s) - 2)
    return s
}

# Single-quote for `set -a; . file` consumption. The ' -> '\'' dance is the only
# escape a POSIX single-quoted string admits.
function shquote(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

# Two output shapes from one traversal:
#
#   mode=shell   (default)  STACK_RUNTIME_KIND='frankenphp'   -> sourced by ssmd
#   mode=dotted             runtime.kind<TAB>frankenphp       -> imported into
#                                                                the config table
#
# One reader, two renderings. A second parser for the database path would be a
# second place for the subset rules to drift.
function keypath(depth,   i, out) {
    if (MODE == "dotted") {
        out = ""
        for (i = 0; i <= depth; i++) out = (out == "") ? path[i] : out "." path[i]
        return out
    }
    out = "STACK"
    for (i = 0; i <= depth; i++) out = out "_" toupper(path[i])
    gsub(/[^A-Z0-9_]/, "_", out)
    return out
}

function emit(name, value) {
    if (name in seen) {
        printf("%s: duplicate key %s (line %d) - later value wins\n", FILENAME, name, NR) > "/dev/stderr"
    }
    seen[name] = 1
    if (MODE == "dotted") {
        # Tab-separated, and newlines inside a list value become \n so one
        # record stays one line. lib/config.sh reverses it on the way out.
        gsub(/\n/, "\\n", value)
        printf("%s\t%s\n", name, value)
    } else {
        printf("%s=%s\n", name, shquote(value))
    }
}

# A pending key is one that had no inline value: it is either a parent map or the
# head of a block list. We only know which after reading the next line, so the
# decision is deferred until flush.
function flush_pending() {
    if (pending_key == "") return
    if (list_n > 0) emit(pending_key, list_buf)
    pending_key = ""; list_buf = ""; list_n = 0
}

BEGIN { pending_key = ""; list_buf = ""; list_n = 0; prev_depth = -1
        MODE = (mode == "") ? "shell" : mode }

{
    line = strip_comment($0)
    if (trim(line) == "") next

    if (line ~ /\t/) {
        printf("%s:%d: tab indentation is not supported - use two spaces\n", FILENAME, NR) > "/dev/stderr"
        next
    }

    match(line, /^ */); indent = RLENGTH
    if (indent % 2 != 0) {
        printf("%s:%d: odd indentation (%d) - use two spaces per level\n", FILENAME, NR, indent) > "/dev/stderr"
        next
    }
    depth = indent / 2
    body = trim(line)

    # ── block list item ─────────────────────────────────────────────────────
    if (body ~ /^- /) {
        if (pending_key == "") {
            printf("%s:%d: list item with no parent key - skipped\n", FILENAME, NR) > "/dev/stderr"
            next
        }
        item = unquote(substr(body, 3))
        if (item ~ /:[ \t]/) {
            printf("%s:%d: maps inside lists are not supported - skipped\n", FILENAME, NR) > "/dev/stderr"
            next
        }
        list_buf = (list_n == 0) ? item : list_buf "\n" item
        list_n++
        next
    }

    # ── key: [value] ────────────────────────────────────────────────────────
    if (body !~ /^[A-Za-z_][A-Za-z0-9_.-]*:/) {
        printf("%s:%d: not a key - skipped: %s\n", FILENAME, NR, body) > "/dev/stderr"
        next
    }

    # A new key at or above the pending key's depth ends any block list.
    if (pending_key != "" && depth <= pending_depth) flush_pending()

    ci = index(body, ":")
    key = substr(body, 1, ci - 1)
    val = trim(substr(body, ci + 1))

    if (depth > prev_depth + 1) {
        printf("%s:%d: indentation jumps more than one level - skipped\n", FILENAME, NR) > "/dev/stderr"
        next
    }
    path[depth] = key
    prev_depth = depth

    if (val == "") {
        # Parent map or block-list head; decided at flush.
        pending_key = keypath(depth); pending_depth = depth
        list_buf = ""; list_n = 0
        next
    }

    # ── inline list ─────────────────────────────────────────────────────────
    if (val ~ /^\[.*\]$/) {
        inner = trim(substr(val, 2, length(val) - 2))
        joined = ""
        if (inner != "") {
            n = split(inner, parts, ",")
            for (i = 1; i <= n; i++) {
                p = unquote(parts[i])
                if (p == "") continue
                joined = (joined == "") ? p : joined "\n" p
            }
        }
        emit(keypath(depth), joined)
        next
    }

    emit(keypath(depth), unquote(val))
}

END { flush_pending() }

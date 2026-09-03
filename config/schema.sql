-- The ssmd config store.
--
-- Everything ssmd knows that is not a secret lives here: configuration, the
-- instance registry, leases, and the audit trail. One file, one backup, one
-- place to look.
--
-- Every statement is IF NOT EXISTS, so this script is the migration: running it
-- against an existing database is a no-op, and running it against a new one
-- builds the whole schema. Adding a column later means adding an ALTER guarded
-- by a check in lib/config.sh, not editing the CREATEs above it.

-- WAL: a `ssmd status` holding a read must never block a `ssmd config set`. The
-- default rollback journal takes a write lock for the whole transaction, which
-- on a laptop with three terminals open is a hang nobody can explain.
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ── configuration ───────────────────────────────────────────────────────────
-- Layered key/value. Resolution is strictly: host:<name> > stack > default.
--
-- Keys are dotted paths ("runtime.kind", "images.proxy"), which is what the
-- YAML seeds flatten to and what `ssmd config get` accepts. Values are always
-- TEXT - SQLite would happily store a typed value, but every consumer is a
-- shell variable or a compose interpolation, so a single representation avoids
-- a class of "8.0 became 8" bugs.
CREATE TABLE IF NOT EXISTS config (
    scope   TEXT NOT NULL,
    key     TEXT NOT NULL,
    value   TEXT NOT NULL,
    origin  TEXT NOT NULL DEFAULT 'set',   -- seed | import | set
    updated TEXT NOT NULL,
    PRIMARY KEY (scope, key)
);

CREATE INDEX IF NOT EXISTS config_key_idx ON config(key);

-- Who changed what, when. The reason this exists rather than just overwriting:
-- "it worked yesterday" is answerable in one query, and a config change made by
-- an agent through the MCP server is distinguishable from one a human made.
CREATE TABLE IF NOT EXISTS config_history (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        TEXT NOT NULL,
    actor     TEXT NOT NULL,
    scope     TEXT NOT NULL,
    key       TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT
);

CREATE INDEX IF NOT EXISTS config_history_key_idx ON config_history(key, ts);

-- Tracks which seed files have been imported and at what mtime, so `ssmd` can
-- re-import automatically when a YAML seed is edited without re-importing on
-- every single invocation.
CREATE TABLE IF NOT EXISTS seed_imports (
    path     TEXT PRIMARY KEY,
    scope    TEXT NOT NULL,
    mtime    INTEGER NOT NULL,
    imported TEXT NOT NULL
);

-- ── instances ───────────────────────────────────────────────────────────────
-- Was a TSV file. Moved here because the registry, the leases and the audit are
-- all answers to "what is going on", and splitting them across three formats
-- meant three ways to be inconsistent.
CREATE TABLE IF NOT EXISTS instances (
    slug     TEXT PRIMARY KEY,
    kind     TEXT NOT NULL,              -- wt | agent
    branch   TEXT,
    worktree TEXT NOT NULL,
    database TEXT,
    -- Redis has sixteen logical databases and the base stack owns 0, so this is
    -- 1-15 and UNIQUE is what enforces the ceiling rather than a comment.
    redis_db INTEGER UNIQUE,
    created  TEXT NOT NULL,
    owner    TEXT
);

CREATE TABLE IF NOT EXISTS leases (
    slug     TEXT PRIMARY KEY REFERENCES instances(slug) ON DELETE CASCADE,
    owner    TEXT NOT NULL,
    acquired INTEGER NOT NULL,
    expires  INTEGER NOT NULL,
    ttl      TEXT
);

-- ── audit ───────────────────────────────────────────────────────────────────
-- Every state-changing ssmd command. The point is to answer "what did the agent
-- actually do" without relying on the agent's account of it.
CREATE TABLE IF NOT EXISTS audit (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     TEXT NOT NULL,
    actor  TEXT NOT NULL,
    event  TEXT NOT NULL,
    detail TEXT
);

CREATE INDEX IF NOT EXISTS audit_ts_idx ON audit(ts);

-- kv: smoke-test plugin. Single key-value table + a notes table
-- with an integer id (used to exercise patch_text).
-- Schema is idempotent so reapplying it on every boot is safe.

CREATE TABLE IF NOT EXISTS kv (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS kv_updated_at_idx ON kv (updated_at DESC);

CREATE TABLE IF NOT EXISTS notes (
  id   INTEGER PRIMARY KEY,
  body TEXT NOT NULL
);

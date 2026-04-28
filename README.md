<img src="./assets/sark.png" alt="SARK" />

A generic SQLite-backed MCP server. Plugins declare their schema (SQL migrations) and a set of canned queries (YAML); sark exposes each query as a typed MCP tool. Agents call the tools, sark validates parameters, runs the SQL, and renders results.

Sark itself is MCP-only and ships no skill format. Skills (Claude Code, Cursor rules, etc.) live alongside the plugin in the same repo and are loaded by whichever MCP client is connected.

Requires Elixir 1.19+.

## Run

```bash
cp config.yml.example config.yml          # edit tokens, plugins
mix sark --config config.yml              # dev
sark --config /etc/sark/config.yml        # release binary (mix release)
```

Sark serves plain HTTP on the configured `listen` address. The MCP endpoint is `POST /mcp`, gated by `Authorization: Bearer <token>`.

## Plugin layout

```
plugin/
  migrations/
    0001_initial.sql       Required. Forward-only SQL, applied once per file.
    0002_add_foo.sql
  queries.yml              Optional. MCP tool definitions.
  queries/                 Optional. Files referenced via `include:` in queries.yml.
    reads.yml
    writes/*.yml
  skills/                  Optional. Travels with the plugin; sark ignores it.
    foo-bar/SKILL.md       Loaded by your MCP client.
```

The plugin name is the directory's basename.

The plugin's SQLite database is created at `{config.data_dir}/{plugin_name}.db` on first boot.

### Migrations

Filenames must match `NNNN_<name>.sql` (zero-padded, contiguous from 1). Applied in order on cold boot. Each file's SQL runs in a transaction; sark tracks which versions have applied. Forward-only — no rollback. **Hot reload does not re-run migrations**; schema changes still require a process restart.

Column documentation lives as SQL comments inside the `CREATE TABLE` statements:

```sql
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,            -- session row id
  started_at TEXT NOT NULL,          -- ISO-8601 UTC timestamp
  location_id INTEGER REFERENCES locations(id)
);
```

Useful if you enable `allow_sql` as then the `catalog` tool will get the schema + comments in response.

### queries.yml

Top-level shape:

```yaml
allow_sql: false               # optional, default false. See "Arbitrary SQL access" below.

include:                       # optional. List of paths or globs (plugin-dir-relative).
  - queries/reads.yml          # literal file (must exist)
  - queries/writes/*.yml       # glob

queries:                       # optional. Inline queries, merged with includes.
  <name>: { ... }
```

All `queries:` blocks across `queries.yml` and any included files are merged into one map. Duplicate names are a hard error.

The MCP tools sark exposes are named `<plugin>_<query>` (e.g. a query `get` in plugin `kv` becomes the tool `kv_get`). Hyphens in plugin names are normalized to underscores. The prefix prevents collisions when multiple plugins running in one sark instance both declare common names like `get` or `list`.

Per-query shape:

```yaml
queries:
  log_set:
    description: Log a completed set during a workout.   # required
    write: true                                          # default false
    returns: results                                     # required
    format: json                                         # optional, see below
    params:
      session_id:  { type: integer, required: true }
      reps:        { type: integer, required: true }
      feeling:     { type: text, required: true, enum: [easy, right, hard] }
      weight_lbs:  { type: real, required: false }
    sql: |
      INSERT INTO sets (session_id, reps, weight_lbs, feeling)
      VALUES (:session_id, :reps, :weight_lbs, :feeling)
      RETURNING id;
```

`sql:` accepts a string (one statement) or a list of strings. With a list, statements run in order, sharing the declared `params:`. Writes wrap all of them in a single transaction. The response is the last statement's result.

```yaml
queries:
  reset_plan:
    description: Wipe pending plan and start a new one.
    write: true
    returns: results
    params:
      location_id: { type: integer, required: true }
      notes:       { type: text, required: false }
    sql:
      - DELETE FROM planned_sessions
      - |
        INSERT INTO planned_sessions (location_id, notes)
        VALUES (:location_id, :notes)
        RETURNING id
```

**`params` spec:**

- `type` — `integer | real | text | blob | null`
- `required` — default `true`
- `default` — applied when omitted and `required: false`
- `enum` — text only, whitelist of accepted values
- `description` — feeds the MCP tool's input schema

Bind variables in SQL use `:name` and reference param names directly.

**`returns` spec:**

- `results` — list of row maps. The default for row-shaped reads or `RETURNING` writes.
- `scalar` — single column of single row (e.g. `SELECT COUNT(*)`).
- `count` — affected row count from a write.
- `none`

**`format` spec:**

- `json` — pretty JSON. Default for writes / scalar / count / none.
- `table` — markdown table.
- `list` — markdown bullets. Default for `returns: results` reads.
- `template` — mustache.

A template format goes inline under the query:

```yaml
queries:
  weekly_report:
    description: Per-muscle weekly volume.
    returns: results
    format:
      kind: template
      template: |
        {{#results}}
        - **{{muscle}}**: {{total_sets}} sets, {{total_reps}} reps
        {{/results}}
    sql: |
      SELECT muscle, SUM(sets) AS total_sets, SUM(reps) AS total_reps
      FROM ...
```

JSON-string columns (e.g. from `json_object` / `json_group_array` in SQL) are auto-decoded into nested data — templates can iterate them with `{{#nested_field}}...{{/nested_field}}`.

**Errors** are returned via MCP `Tool.error` with one of three prefixes:

- `validation: ...` — bad params, caught before SQL runs (LLM-actionable, retry with fix)
- `constraint: ...` — SQLite integrity violation (FK, CHECK, UNIQUE)
- `internal: ...` — unexpected; full detail logged server-side, generic message to client

## Arbitrary SQL access

Two extra tools — `catalog` and `sql_query` — let an MCP client introspect the schema and run ad-hoc read-only SQL. Both are off by default. Opt in per plugin:

```yaml
# queries.yml
allow_sql: true
```

When enabled:

- **`catalog`** returns the live schema and the list of canned queries with their parameter schemas:

  ```json
  {
    "name": "kv",
    "schema": [
      { "type": "table", "name": "kv", "sql": "CREATE TABLE kv (...)" },
      { "type": "index", "name": "kv_updated_at_idx", "sql": "..." }
    ],
    "queries": [
      { "name": "get", "description": "Look up a row by key.", "params": [...], ... }
    ]
  }
  ```

- **`sql_query(sql)`** runs an arbitrary `SELECT` / `WITH` / `PRAGMA`.

Most plugins should leave `allow_sql: false` and expose only their curated canned queries — those have validated parameter types, structured response formats, and stable contracts the skill is written against. Leaving it enabled with unsupervised agents will probably eventually result in something like `DELETE FROM tasks;`.

## `patch_text`

Every plugin gets a `patch_text(table, id, col, old, new)` tool. It reads `col` from the row matching `id`, replaces every occurrence of the `old` substring with `new`, and writes the result back — all in one writer transaction. Returns the number of replacements made. Errors if `old` doesn't appear in the column (so a typo doesn't silently no-op).

The point is surgical edits without round-tripping the whole field. A plugin can store a long markdown body in a column and patch a single paragraph or sentence:

```
patch_text(table='notes', id=1, col='body',
           old='There are 50 servers in the pool.',
           new='There are 100 servers in the pool.')
```

`patch_text` is unconditional — it operates on identifier-validated `table` / `col` arguments, never arbitrary SQL. The plugin's skill should explain which fields are intended for it (e.g. "`patch_text` the `notes.body` column when revising notes").

## Hot reload

Each plugin runs a file watcher with a 200ms debounce. When `queries.yml`, any included file, or anything else under the plugin directory ending in `.yml` / `.yaml` changes, sark re-runs the loader and re-registers the MCP tools.

Migrations and database files (`*.db`, `*.db-shm`, `*.db-wal`) are ignored. Reload errors are caught and logged; the previous registration stays in place.

Disable per-deployment with `hot_reload: false` in config.

> Note: tool changes take effect server-side immediately, but most MCP clients (Claude Code included) cache the tool list at session start and need a reconnect to see new tools. Existing tools work without reconnect if they have the same params.

## Config

```yaml
listen: 127.0.0.1:8080            # required. IP:PORT, IPs only (no DNS).
data_dir: ./dev_data              # required. Per-plugin DB files live here.
log_level: info                   # debug | info | warning | error

hot_reload: true                  # optional, default true.

tokens:                           # required. Bearer auth, per-device names.
  - { name: laptop, token: "${SARK_LAPTOP_TOKEN}" }
  - { name: phone,  token: sk-... }

plugins:                          # required. Absolute, or relative to config file.
  - /srv/sark-plugins/foo
  - ../my-plugin
```

`${VAR}` interpolation pulls from environment variables at boot. A missing env reference raises hard.

## Implementing a plugin

Shortest path:

1. Create the plugin directory (example here is `kv`) with `migrations/0001_initial.sql`.

    ```sql
    CREATE TABLE IF NOT EXISTS kv (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );
    ```

2. Add `queries.yml`:

    ```yaml
    queries:
      put:
        description: Upsert a key
        returns: results
        write: true
        params:
          key:   { type: text }
          value: { type: text }
        sql: |
          INSERT INTO kv (key, value) VALUES (:key, :value)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          RETURNING key

      get:
        description: Look up a row by key, rendered as a template.
        returns: results
        params:
          key: { type: text }
        sql: |
          SELECT key, value FROM kv WHERE key = :key
    ```

3. Add the path to `plugins:` in `config.yml`.
4. Boot sark. The plugin's database is created and migration 1 is applied.
5. Connect your MCP client, i.e. `claude mcp add --transport http --scope project mysark http://localhost:8080/mcp --header "Authorization: Bearer sk-mytoken"`
6. Say something like: `use sark kv, store "x" = 1`, then in a new session `what did i store in sark kv for 'x'?`

Usage:

- **Skills should carry domain knowledge.** Vocabularies, heuristics, conversation flow live in skill prose. Sark queries are the verbs the skill orchestrates.
- **Composite reads.** Bundle nested data using `json_object` / `json_group_array` in SQL. Sark auto-decodes the JSON-string columns; templates iterate them directly.
- **Atomic per tool call.** Each `write: true` query wraps in a writer-pool transaction; failures roll back automatically.

The `kv` test fixture under `test/fixtures/plugins/kv/` is the canonical example — it covers every return shape × format and demonstrates the `include:` split (literal + glob + inline coexistence).

### Versioning a column

Use a trigger:

```sql
-- shadow table — one row per pre-update snapshot
CREATE TABLE notes_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL,
  body TEXT NOT NULL,
  replaced_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- trigger pushes the old row into history before every UPDATE
CREATE TRIGGER notes_versioning
BEFORE UPDATE ON notes
BEGIN
  INSERT INTO notes_history (note_id, body) VALUES (OLD.id, OLD.body);
END;
```

Any `UPDATE` to `notes` fires the trigger and lands a snapshot in `notes_history`. Reads against `notes_history` work like any other table — expose them via canned queries.

You could do bounded retention in the trigger, or add a prune query the skill can run:

```yaml
prune_notes_history:
  description: Keep the most recent N versions per note.
  write: true
  returns: count
  params:
    note_id: { type: integer, required: true }
    keep:    { type: integer, required: false, default: 10 }
  sql: |
    DELETE FROM notes_history
    WHERE note_id = :note_id
      AND id NOT IN (
        SELECT id FROM notes_history
        WHERE note_id = :note_id
        ORDER BY replaced_at DESC
        LIMIT :keep
      )
```


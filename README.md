# sark

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

## patch_text

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

> Note: tool changes take effect server-side immediately, but most MCP clients (Claude Code included) cache the tool list at session start and need a reconnect to see new tools. Existing tools work without reconnect.

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

1. Create the plugin directory with `migrations/0001_initial.sql`.
2. Add the path to `plugins:` in `config.yml`.
3. Boot sark. The plugin's database is created and migration 1 is applied. `patch_text` registers automatically.
4. Add `queries.yml` (and optionally `include:` + a `queries/` subdirectory). Save the file — hot reload re-registers tools.
5. Reconnect your MCP client to see the new tool names.
6. Iterate on queries; restart for schema changes (a new migration).

Notes:

- **Skills carry domain knowledge.** Vocabularies, heuristics, conversation flow live in skill prose. Sark queries are the verbs the skill orchestrates.
- **Composite reads.** Bundle nested data using `json_object` / `json_group_array` in SQL. Sark auto-decodes the JSON-string columns; templates iterate them directly.
- **Multi-step writes.** No native multi-statement query body — either inline the steps as `;`-separated SQL in one query (single transaction), or sequence multiple tool calls.
- **Atomic per tool call.** Each `write: true` query wraps in a writer-pool transaction; failures roll back automatically.
- **Per-write events.** Every successful write broadcasts on `Phoenix.PubSub` topic `<plugin>.<query>` for any in-process subscribers.

The `kv` test fixture under `test/fixtures/plugins/kv/` is the canonical example — it covers every return shape × format and demonstrates the `include:` split (literal + glob + inline coexistence).

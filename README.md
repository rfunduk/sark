<img src="./assets/sark.png" alt="SARK" />

A generic SQLite-backed MCP server. Plugins declare their schema (SQL migrations) and a set of canned queries (YAML); sark exposes each query as a typed MCP tool. Agents call the tools, sark validates parameters, runs the SQL, and renders results.

Sark itself is MCP-only and ships no skill format. Skills (Claude Code, Cursor rules, etc.) live alongside the plugin in the same repo and are loaded by whichever MCP client is connected.

## Run

```bash
cp config.yml.example config.yml          # edit tokens, plugins
sark --config /etc/sark/config.yml        # release binary
```

Building from source requires Elixir 1.19+; `mix sark --config config.yml` is the dev equivalent.

Sark serves plain HTTP on the configured `listen` address. Each plugin gets its own MCP endpoint at `POST /<plugin>/mcp`.

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
  workers.yml              Optional. Background-agent definitions.
  workers/                 Optional. Files referenced via `include:` in workers.yml.
    *.yml
  skills/                  Optional. Travels with the plugin; sark ignores it.
    foo-bar/SKILL.md       Loaded by your MCP client.
```

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

Each plugin runs its own MCP router at `/<plugin>/mcp`, so tools are exposed under their bare query name (e.g. a query `get` in plugin `kv` is the tool `get` on the `kv` endpoint). Plugin names must match `[a-z0-9][a-z0-9_-]*`.

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

- `type` — `integer | real | text | blob | boolean | array | object`
- `required` — default `true`
- `default` — applied when omitted and `required: false` (scalars only)
- `enum` — text only, whitelist of accepted values
- `description` — feeds the MCP tool's input schema
- `items` — required when `type: array`. A nested value spec describing each element.
- `properties` — required when `type: object`. A map of named param specs (recurses).

Bind variables in SQL use `:name` and reference param names directly.

**Booleans** `true` / `false` bound to SQLite `1` / `0` (SQLite has no native bool).

**Omitted optional params bind as SQL `NULL`.** Useful for `(:project_id IS NULL OR project_id = :project_id)` style filters that toggle on parameter presence without rewriting the query.

### Array + object params

`array` and `object` params let an agent pass structured data in a single tool call, atomically. Sark validates the shape recursively, then JSON-encodes the value before binding it as TEXT — your SQL fans it out with `json_each` / `json_extract` (SQLite's built-in json1).

```yaml
log_sets:
  description: Insert many sets in one call.
  write: true
  returns: count
  params:
    session_id: { type: integer, required: true }
    sets:
      type: array
      required: true
      items:
        type: object
        properties:
          exercise_id: { type: integer, required: true }
          set_number:  { type: integer, required: true }
          reps:        { type: integer, required: true }
          weight_lbs:  { type: real, required: false }
          feeling:     { type: text, required: true, enum: [easy, right, hard] }
  sql: |
    INSERT INTO sets (session_id, exercise_id, set_number, reps, weight_lbs, feeling)
    SELECT :session_id,
           json_extract(value, '$.exercise_id'),
           json_extract(value, '$.set_number'),
           json_extract(value, '$.reps'),
           json_extract(value, '$.weight_lbs'),
           json_extract(value, '$.feeling')
    FROM json_each(:sets)
```

The agent calls one tool with the whole batch; sark validates each element against `items:` before any SQL runs and returns path-qualified errors (`sets[2].reps must be an integer`). The SQLite layer sees one prepared INSERT...SELECT inside one transaction.

**`returns` spec:**

- `results` — list of row maps. The default for row-shaped reads or `RETURNING` writes.
- `scalar` — single column of single row (e.g. `SELECT COUNT(*)`).
- `count` — affected row count from a write. **In SQLite, `count = 0` unambiguously means "WHERE matched no rows" — not "matched but values were already correct".** SQLite counts every row the UPDATE touched, regardless of whether the SET changed any value. So callers can treat `0` as "not found" without ambiguity.
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

For an empty-state fallback, use mustache's inverted section `{{^results}}...{{/results}}` — rendered when the list is empty:

```yaml
format:
  kind: template
  template: |
    {{#results}}
    - {{title}}
    {{/results}}
    {{^results}}
    _no entries yet_
    {{/results}}
```

**Errors** are returned via MCP `Tool.error` with one of four prefixes:

- `validation: ...` — bad params, caught before SQL runs (LLM-actionable, retry with fix)
- `rejected: ...` — pre-flight `reject:` check tripped; message is the entry's template (LLM-actionable)
- `constraint: ...` — SQLite integrity violation (FK, CHECK, UNIQUE)
- `internal: ...` — unexpected; full detail logged server-side, generic message to client

### `reject:` pre-flight checks

State preconditions — "row already closed", "prefix matches multiple rows" — that param validation can't catch. Each entry is a `SELECT` plus a message; rows returned → reject (main `sql:` skipped, message returned). Empty → pass, next reject runs. First non-empty short-circuits.

```yaml
queries:
  close_task:
    write: true
    returns: count
    params:
      id: { type: integer }
    reject:
      - sql: SELECT 1 FROM tasks WHERE id = :id AND status = 'closed'
        message: "task {id} already closed"
    sql: UPDATE tasks SET status = 'closed' WHERE id = :id
```

`{name}` in `message:` interpolates the param value. Multiple checks run in declaration order:

```yaml
reject:
  - sql: |
      SELECT 1 FROM tasks WHERE id LIKE :id || '%'
      GROUP BY 1 HAVING COUNT(*) > 1
    message: "ambiguous prefix '{id}'"
  - sql: SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE id LIKE :id || '%')
    message: "no task matches '{id}'"
```

For `write: true` queries, rejects run inside the same transaction as the main statement — preconditions can't race against another writer.

Reject SQL must be plain `SELECT` (no `INSERT`/`UPDATE`/`DELETE`/`WITH`/`PRAGMA`); enforced at load. Same `:bind` params as `sql:`.

### `shared:` fragments (`@name` references)

Repeated reject blocks (or any other repeated structure) can live in a
top-level `shared:` map and be referenced from anywhere in the document
with `@name`:

```yaml
shared:
  prefix_rejects:
    - sql: |
        SELECT 1 FROM tasks WHERE id LIKE :id || '%' AND status='open'
        GROUP BY 1 HAVING COUNT(*) > 1
      message: "ambiguous prefix '{id}' — call resolve first"
    - sql: SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE id LIKE :id || '%')
      message: "no task matches prefix '{id}'"

queries:
  update:
    write: true
    returns: count
    params: { id: { type: text }, ... }
    reject: @prefix_rejects     # whole-value substitution
    sql: UPDATE tasks SET ... WHERE id = ...

  set_status:
    write: true
    returns: count
    params: { id: { type: text }, ... }
    reject:
      - @prefix_rejects          # spliced (since fragment is a list)
      - sql: SELECT 1 FROM tasks WHERE id = :id AND status = :status
        message: "task already in status '{status}'"
    sql: UPDATE tasks SET status = :status WHERE id = ...
```

Rules:

- `shared:` is a top-level map (sibling to `queries:` and `include:`),
  one per file. All `shared:` blocks across `queries.yml` and any
  included files are merged. Duplicate fragment names across files raise
  at load.
- A string starting with `@` is a fragment reference. `@name` looks up
  `shared.name`.
- **Whole-value substitution.** `field: @name` → fragment value sits
  literally in place.
- **List-element splice.** `[..., @name, ...]` — if the fragment is a
  list, it's flattened in; if it's a single value, it's inserted as one
  element.
- Resolution is universal — any field can reference fragments, not just
  `reject:`. Fragments may reference other fragments (cycles raise).
- Unknown `@name` raises at parse time with the list of defined
  fragments. Typos fail loud.

### Worker-only queries (`internal: true`)

A query marked `internal: true` is **not** registered as an MCP tool. External clients (Claude Code, Cursor, curl) can't see it or call it, and it's omitted from the `catalog` response. The query is still loaded into the plugin's registry and is reachable from inside the same plugin's workers (see [Workers](#workers) below). Same parameter validation, same transactions, same renderers — just hidden from the public surface.

```yaml
queries:
  flag_reconciled:
    description: Mark a row as reconciled. Worker-only — users shouldn't forge this.
    internal: true
    write: true
    returns: count
    params:
      id: { type: integer }
    sql: |
      UPDATE rows SET reconciled_at = datetime('now') WHERE id = :id
```

Use it for things like writing system-only event kinds, flipping server-managed columns, or reading shadow/history tables that shouldn't be part of the public contract.

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

**Non-integer primary keys.** `id` accepts any scalar that SQLite can match — integers or strings. If your table is keyed by a slug, declare it `TEXT PRIMARY KEY` and `patch_text` works directly without a slug→id round-trip:

```sql
CREATE TABLE tasks (
  slug TEXT PRIMARY KEY,
  body TEXT NOT NULL
);
```

```
patch_text(table='tasks', id='my-task', col='body', old='foo', new='bar')
```

The `id` parameter just goes into the `WHERE id = ?` clause as-is.

> Note: built-in tool names — `patch_text`, `catalog`, `sql_query` — are reserved. Naming a query in `queries.yml` after one of them is a hard error at registration time.

## Hot reload

Each plugin runs a file watcher with a 200ms debounce. When `queries.yml`, any included file, or anything else under the plugin directory ending in `.yml` / `.yaml` changes, sark re-runs the loader and re-registers the MCP tools.

Migrations and database files (`*.db`, `*.db-shm`, `*.db-wal`) are ignored. Reload errors are caught and logged; the previous registration stays in place.

Disable per-deployment with `hot_reload: false` in config.

> Note: tool changes take effect server-side immediately, but most MCP clients (Claude Code included) cache the tool list at session start and need a reconnect to see new tools. **Existing tools work without reconnect as long as their `params:` block is unchanged** — SQL, description, returns, format can all change freely. Adding/removing/renaming a param, or changing its type or `required` flag, is a signature change and needs a reconnect for the client to pick up the new schema.

## Config

```yaml
listen: 127.0.0.1:8080            # required. IP:PORT, IPs only (no DNS).
data_dir: ./dev_data              # required. Per-plugin DB files live here.
log_level: info                   # debug | info | warning | error

hot_reload: true                  # optional, default true.

tokens:                           # required. Bearer auth, list plugins or * for all
  - { name: laptop, plugins: ["*"],     token: "${SARK_LAPTOP_TOKEN}" }
  - { name: phone,  plugins: [tasks, kv], token: sk-... }

plugins:                          # required. Map of name → directory.
  kv: /srv/sark-plugins/kv        # Paths absolute or relative to this config file.
  tasks: ../my-task-plugin
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

3. Add the plugin to `plugins:` in `config.yml` (e.g. `kv: ../kv`) and ensure a token is scoped to it (`plugins: ["*"]` or `plugins: [kv]`).
4. Boot sark. The plugin's database is created and migration 1 is applied.
5. Connect your MCP client, i.e. `claude mcp add --transport http --scope project sark-kv http://localhost:8080/kv/mcp --header "Authorization: Bearer sk-mytoken"`
6. Say something like: `use sark kv, store "x" = 1`, then in a new session `what did i store in sark kv for 'x'?`

Usage:

- **Skills should carry domain knowledge.** Vocabularies, heuristics, conversation flow live in skill prose. Sark queries are the verbs the skill orchestrates.
- **Composite reads.** Bundle nested data using `json_object` / `json_group_array` in SQL. Sark auto-decodes the JSON-string columns; templates iterate them directly.
- **Atomic per tool call.** Each `write: true` query runs in a transaction; failures roll back automatically.

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

> Triggers writing to a *different* table (the case above) are safe by default. Triggers that touch the *same* table they fire on (e.g. `AFTER UPDATE ON notes` that updates `notes.updated_at`) need SQLite's `recursive_triggers` PRAGMA disabled (it is, by default) or careful guards to avoid recursion. Easier: bump `updated_at` directly in your `UPDATE` statement instead of via trigger.

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

## Workers

**Still in development.**

A worker is a background LLM agent owned by a plugin. It calls the plugin's MCP tools the same way any external client does — same `queries.yml` surface, same handlers — except the loop runs inside sark itself, driven by an Anthropic model the plugin author picks. Workers are how a plugin grows ambient behavior: nightly digests, cross-row pattern detection, periodic summaries.

**No scheduler** — workers fire on manual invocation only. They don't run on cron or events.

### workers.yml

Top-level shape mirrors `queries.yml`:

```yaml
include:                  # optional. Paths or globs (plugin-dir-relative).
  - workers/*.yml

workers:                  # optional. Inline workers, merged with includes.
  <name>: { ... }
```

All `workers:` blocks across `workers.yml` and any included files merge into one map. Duplicate names are a hard error.

Per-worker shape:

```yaml
workers:
  reconciler:
    description: Reconcile drift on stale active tasks. # required
    model: claude-sonnet-4-6                            # required. Any Anthropic model id.
    tools: [show, mark_reconciled]                      # required. Allowlist; tools live in this plugin.
    max_turns: 8                                        # optional, default 8.

    when: |                                             # optional. Empty result → skip (no LLM call, no log row).
      SELECT 1 WHERE EXISTS (
        SELECT 1 FROM tasks
        WHERE status = 'active'
          AND (reconciled_at IS NULL OR reconciled_at < updated_at)
      )

    load: |                                             # optional. Rows feed mustache rendering of `prompt:`.
      SELECT
        COUNT(*) AS pending,
        MIN(updated_at) AS oldest_stale,
        json_group_array(json_object('slug', slug, 'title', title)) AS queue
      FROM tasks
      WHERE status = 'active'
        AND (reconciled_at IS NULL OR reconciled_at < updated_at)

    system: |                                           # required. NO mustache — sent verbatim and cached.
      You are the task reconciler. ...

    prompt: |                                           # required. Mustache-rendered against `load:` rows.
      {{pending}} tasks pending reconcile. Oldest stale since {{oldest_stale}}.

      Queue:
      {{#queue}}
      - `{{slug}}` — {{title}}
      {{/queue}}
```

**Field notes:**

- `tools` is an allowlist of bare tool names from this plugin's `queries.yml` (including any `internal: true` queries — workers can call those, external clients can't) plus the plugin's built-ins (`patch_text`, plus `catalog` and `sql_query` when `allow_sql: true`). Tools outside the list are invisible to the LLM. Unknown names raise at startup. Cross-plugin (`<plugin>.<tool>`) is not supported.
- `when:` is parameterless SQL. **Empty result set → worker is skipped entirely** (no LLM call, no `_worker_log` row). One or more rows → run. Use it to short-circuit when there's nothing to do.
- `load:` is parameterless SQL. Result rows render `prompt:` via mustache:
  - 0 rows → empty context (vars expand to `""`).
  - 1 row → columns bind as scalars (`{{pending}}`). JSON aggregate columns (`json_group_array(...)`) are auto-decoded, so `{{#queue}}…{{/queue}}` iterates over them.
  - >1 rows → bound under `{{#results}}…{{/results}}`.
- `system:` must not contain mustache (`{{...}}`) — it's sent verbatim and cached. Any `{{` in `system:` raises at startup.
- `prompt:` is mustache-rendered **before** the LLM sees it. `load:` populates the context; without `load:` the prompt is sent as-is.
- `max_turns` caps the tool-use loop. The runner aborts if the model is still calling tools after this many turns.

### Caching + cost telemetry

Sark caches the `system:` block and tool definitions across turns within a single run, so subsequent turns hit the prompt cache. The 5-minute TTL means workers running on long cadences (daily / weekly) won't carry cache hits across runs — that's expected.

Every terminal worker state writes one row to a sark-managed `_worker_log` table in the plugin's own database. Columns:

| column                  | meaning                                                              |
| ----------------------- | -------------------------------------------------------------------- |
| `worker_name`           | `"<name>"` from `workers.yml`                                        |
| `model`                 | model id sent to the provider                                        |
| `started_at`/`ended_at` | ISO8601 UTC                                                          |
| `turns`                 | tool-use loop iterations                                             |
| `stop_reason`           | `end_turn` / `max_tokens` / `stop_sequence` / `max_turns_exceeded` / `error` |
| `input_tokens`          | summed across turns                                                  |
| `output_tokens`         | summed across turns                                                  |
| `cache_read_tokens`     | summed across turns                                                  |
| `cache_creation_tokens` | summed across turns                                                  |
| `service_tier`          | latest non-nil value reported by the provider                        |
| `error`                 | error string on `error`, NULL otherwise                              |
| `final_output`          | text from the last assistant turn                                    |

Runs that the `when:` gate skipped do not log — there's no run to record.

### Manual trigger

```bash
mix sark.worker --config config.yml tasks.dreamer
```

The argument is `<plugin>.<worker>`. Looks up the named worker, runs it once, and streams a turn-by-turn transcript to stdout. Currently source-only — no release-binary equivalent yet.

The Anthropic API key comes from `anthropic_api_key` in `config.yml`. Use a literal value for dev or `${VAR}` for env interpolation in prod:

```yaml
anthropic_api_key: "${ANTHROPIC_API_KEY}"
```

Each invocation is a fresh conversation — no resume, no memory between runs.

### What a worker run looks like

```
running worker tasks.dreamer (model=claude-sonnet-4-6, max_turns=8)

--- turn 1 ---
[assistant] Scanning recent activity.
[tool_call #toolu_01a] list_active({})
[tool_result #toolu_01a ok] - L2 workers — agentic substrate (`l2-workers`) ...

--- turn 2 ---
[assistant] Found a cross-task pattern between l2-workers and plugin-test-harness.
[tool_call #toolu_02a] append({"slug":"l2-workers","section":"findings","text":"..."})
[tool_result #toolu_02a ok] 1

--- turn 3 ---
[assistant] Done.

[stop] reason=:end_turn turns=3

[done] turns=3 stop=:end_turn
```

Each `[tool_call ...]` was dispatched in-process through the same handler an external MCP client would hit. Errors come back to the LLM as tool_result blocks with `is_error: true`, so the model can recover.

### Limits

- **No scheduling.** Cron and event triggers aren't wired. Workers fire on manual invocation only.
- **No hot reload of `workers.yml`.** Edit + restart the process.
- **No token/cost budget enforcement.** Worker runs to completion or `max_turns`. Cost telemetry is captured in `_worker_log`; enforcement on top of that is not.
- **No retry on Anthropic 5xx.** Failure aborts the loop.
- **No streaming.** Each LLM turn blocks for the full response before tool dispatch.
- **Plugin-local tools only.** A worker can't call another plugin's tools.

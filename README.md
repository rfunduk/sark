<img src="./assets/sark.png" alt="SARK" />

A generic SQLite-backed MCP server. Plugins declare their schema (SQL migrations) and a set of canned queries (YAML); Sark exposes each query as a typed MCP tool. Agents call the tools, Sark validates parameters, runs the SQL, and renders results.

Sark is MCP-only and ships no skill format. Skills (Claude Code, Cursor rules, etc.) are a separate concern and you can handle them as you prefer -- you might have them co-located with the plugin, or in a separate 'AI marketplace', or just locally on your machine.

## FAQ

*Why?* I want my agents to use skills to do things but with some storage backend. Often it's fine to just have the agent write markdown files somewhere and the skills can refer to them, but this breaks down quickly -- just like my 'dotfiles', I want my todo list or whatever from any machine I use, and my phone too.

*But doesn't MCP suck?* There are very many sucky MCP servers, but as a protocol I think it's great. Sark provides tools you can use to craft an agent friendly response from your database (so you arent just pooping out a huge JSON blob).

*What agents are supported?* Personally I'm primarily using Claude Code. But since MCP is a standard and Sark has no opinions on skills structure, you can pretty much do anything you want. Maybe you want to use hooks to inject usage of your MCP into every session, or maybe you want to invoke the tools manually `/with-slash-commands`, or anything else you can think of.

## Usage

Pull the published image and run it:

```bash
docker run -d --name sark \
  -p 8080:8080 \
  -v /path/to/storage:/storage \
  -v /path/to/plugins:/storage/plugins \
  -e SARK_CONFIG=/storage/config.yml \
  ghcr.io/rfunduk/sark:latest
```

Or build image instead of pulling:

```bash
docker build -t sark-dev .
docker run ...
```

Or build from source if you have Elixir 1.19+:

```
mix deps.get
SARK_CONFIG=config.dev.yml mix sark
```

As you can see, you need a config file -- see [`config.yml.example`](./config.yml.example)


## Your First Plugin

Shortest path:

1. Create the plugin directory (example here is `kv`) with `migrations/0001_initial.sql`.

    ```sql
    CREATE TABLE IF NOT EXISTS kv (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );
    ```

2. Add `plugin.yml`:

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

3. Add the plugin to `plugins:` in `config.yml` (e.g. `kv: /storage/plugins/kv`) and ensure a token is scoped to it (`plugins: ["*"]` or `plugins: [kv]`).
4. Boot Sark. The plugin's database is created and migration 1 is applied.
5. Connect your MCP client, i.e. `claude mcp add --transport http --scope project sark-kv http://localhost:8080/kv/mcp --header "Authorization: Bearer sk-mytoken"`. Clients that can't set custom headers can pass the token as `?token=mytoken` instead.
6. Say something like: `use sark kv, store "x" = 1`, then in a new session `what did i store in sark kv for 'x'?`

### Tips

- **Skills should carry domain knowledge.** Vocabularies, heuristics, conversation flow live in skill prose. Sark queries are the verbs the skill orchestrates.
- **Composite reads.** Bundle nested data using `json_object` / `json_group_array` in SQL. Sark auto-decodes the JSON-string columns; templates iterate them directly.
- **Atomic per tool call.** Each `write: true` query runs in a transaction; failures roll back automatically.


## Plugin Authoring

Each plugin runs its own MCP router at `/<plugin>/mcp`, so tools are exposed under their query name.

### Layout

```
myplugin/
  migrations/
    0001_initial.sql
    0002_add_foo.sql
  plugin.yml
  skills/                  # Sark will ignore. Point Claude here.
    foo-bar/SKILL.md
```

### Migrations

Filenames must match `NNNN_<name>.sql` (zero-padded, contiguous from 1). Applied in order on cold boot. Each file's SQL runs in a transaction; Sark tracks which versions have applied. Forward-only — no rollback.

Column documentation lives as SQL comments inside the `CREATE TABLE` statements:

```sql
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,            -- session row id
  started_at TEXT NOT NULL,          -- ISO-8601 UTC timestamp
  location_id INTEGER REFERENCES locations(id)
);
```

Useful if you enable `allow_sql` as then the `sark_catalog` tool will get the schema + comments in response.

### `plugin.yml`

Create a `plugin.yml` for each plugin:

```yaml
allow_sql: false               # optional, default false. See "Arbitrary SQL access"

include:
  - otherfile.yml
  - stuff/*.yml

patchable:
  <table>: [<column>, ...]

shared:
  <name>: ...

queries:
  <name>: { ... }

workers:
  <name>: { ... }
```

More on all of these below.

## Queries

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

The agent calls one tool with the whole batch; Sark validates each element against `items:` before any SQL runs and returns path-qualified errors (`sets[2].reps must be an integer`). The SQLite layer sees one prepared INSERT...SELECT inside one transaction.

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

### Worker-only queries (`internal: true`)

A query marked `internal: true` is **not** registered as an MCP tool. External clients (Claude Code, Cursor, curl) can't see it or call it, and it's omitted from the `sark_catalog` response.

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


## Shared Fragments

A `shared:` entry is any reusable subtree — a `params:` block, a `format:`, a reject list, a worker's `tools:`/`system:`, whatever. `@name` substitutes it into **any field of any query or worker**. Example:

```yaml
shared:
  id: { type: text, required: true }   # a single param spec

  pagination:                          # a params sub-block
    limit:  { type: integer, required: false, default: 20 }
    offset: { type: integer, required: false, default: 0 }

  card:                                # a format object
    kind: template
    template: "{{#results}}- {{name}}{{/results}}"

  reader_tools: [list, get]            # a worker tools list

  prefix_rejects:                      # a reject list
    - sql: |
        SELECT 1 FROM tasks WHERE id LIKE :id || '%' AND status='open'
        GROUP BY 1 HAVING COUNT(*) > 1
      message: "ambiguous prefix '{id}' — call resolve first"
    - sql: SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE id LIKE :id || '%')
      message: "no task matches prefix '{id}'"

queries:
  list:
    returns: results
    params: @pagination
    format: @card
    sql: SELECT name FROM tasks LIMIT :limit OFFSET :offset

  update:
    write: true
    returns: count
    params: { id: @id, status: { type: text } }
    reject:
      - @prefix_rejects                # spliced (fragment is a list)
      - sql: SELECT 1 FROM tasks WHERE id = :id AND status = :status
        message: "task already in status '{status}'"
    sql: UPDATE tasks SET status = :status WHERE id = :id

workers:
  janitor:
    description: ...
    model: claude-haiku-4-5
    tools: @reader_tools               # @name resolves in workers too
    system: ...
    prompt: ...
    schedule: "0 3 * * *"
```

Rules:

- A string starting with `@` is a fragment reference. `@name` looks up `shared.name`.
- **Whole-value substitution.** `field: @name` → fragment value sits literally in place.
- **List-element splice.** `[..., @name, ...]` — if the fragment is a list, it's flattened in; if it's a single value, it's inserted as one element.
- Fragments may reference other fragments.


## Arbitrary SQL access

Two extra tools — `sark_catalog` and `sark_sql` — let an MCP client introspect the schema and run ad-hoc read-only SQL. Both are off by default. Opt in per plugin:

```yaml
# plugin.yml
allow_sql: true
```

When enabled:

- **`sark_catalog`** returns the live schema and the list of canned queries with their parameter schemas:

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

- **`sark_sql(sql)`** runs an arbitrary `SELECT` / `WITH` / `PRAGMA`.

Most plugins should leave `allow_sql: false` and expose only their curated canned queries — those have validated parameter types, structured response formats, and stable contracts the skill is written against. Leaving it enabled with unsupervised agents will probably eventually result in something like `DELETE FROM tasks;`.


## Patchable

`plugin.yml` declares the allow-list at the top level:

```yaml
patchable:
  notes: [body]
  tasks: [body, title]
```

Map of `table → [column, ...]`. Both sides are validated as SQL identifiers at load time. **The default is empty — `sark_patch` rejects every call until the plugin author opts specific fields in.** Locked-down by default; the plugin author decides what's editable.

The tool is always registered (so the agent gets a useful error instead of "tool not found"). Its description lists the allowed paths up front, e.g. `Patchable: notes.body, tasks.body, tasks.title.`

The plugin's skill should explain which fields are intended for it (e.g. "`sark_patch` the `notes.body` column when revising notes").

### `sark_patch`

Every plugin gets a `sark_patch(table, id, col, old, new)` tool. It reads `col` from the row matching `id`, replaces every occurrence of the `old` substring with `new`, and writes the result back — all in one writer transaction. Returns the number of replacements made. Errors if `old` doesn't appear in the column (so a typo doesn't silently no-op).

The point is surgical edits without round-tripping the whole field. A plugin can store a long markdown body in a column and patch a single paragraph or sentence:

```
sark_patch(table='notes', id=1, col='body',
           old='There are 50 servers in the pool.',
           new='There are 100 servers in the pool.')
```

`sark_patch` is identifier-validated (never arbitrary SQL) and locked down by default.


## Workers

A worker is a background LLM agent owned by a plugin. It calls the plugin's MCP tools the same way any external client does — same `plugin.yml` surface, same handlers — except the loop runs inside Sark itself, driven by an Anthropic model the plugin author picks. Workers are how a plugin grows ambient behavior: nightly digests, cross-row pattern detection, periodic summaries.

### Defining workers

Workers live under the `workers:` key — inline in `plugin.yml` or in any `include:`d file:

```yaml
workers:
  rollup:
    description: Nightly — fold each task's accumulated comments into its summary body.
    model: claude-sonnet-4-6                            # required. Any Anthropic model id.
    schedule: "0 3 * * *"                               # required. Cron schedule.
    tools: [task_with_comments, archive_comments]       # required. Allowlist; tools live in this plugin.
    max_turns: 16                                       # optional, default 8.

    when: |                                             # optional. Empty result → skip (no LLM call, no log row).
      SELECT 1 WHERE EXISTS (
        SELECT 1 FROM task_comments
        WHERE archived_at IS NULL
          AND created_at < datetime('now', '-1 day')
      )

    load: |                                             # optional. Rows feed mustache rendering of `prompt:`.
      SELECT
        id, title, body,
        json_group_array(json_object('id', c.id, 'body', c.body, 'at', c.created_at)) AS comments
      FROM tasks t
      JOIN task_comments c ON c.task_id = t.id
      WHERE c.archived_at IS NULL
      GROUP BY t.id

    system: |                                           # required. NO mustache — sent verbatim and cached.
      # Role + output rules + invariants. Stable across every run.
      # Anything identical between two invocations belongs here.
      You roll up task comments into the task summary body.
      For each task: call `task_with_comments` to read current state,
      compose an updated body that integrates the comment content
      (preserve facts, drop redundancy, keep markdown structure).
      Later comments override previous comments or the body on conflict.
      Use `sark_patch` to update the body, then `archive_comments` with
      the comment ids you folded. Never invent facts. Stop when every
      task in the queue is handled.

    prompt: |                                           # required. Mustache-rendered against `load:` rows.
      # Per-run data. Mustache vars from `load:`. Anything that
      # varies between invocations belongs here.
      Tasks with unfolded comments:
      {{#results}}
      - `{{id}}` — {{title}}
      {{/results}}
```

**Field notes:**

- `tools` is an allowlist of bare tool names from this plugin's `plugin.yml` (including any `internal: true` queries — workers can call those, external clients can't) plus the plugin's built-ins (`sark_patch`, plus `sark_catalog` and `sark_sql` when `allow_sql: true`). Tools outside the list are invisible to the LLM. Unknown names raise at startup.
- `when:` is parameterless SQL. **Empty result set → worker is skipped entirely** (no LLM call, no `_worker_log` row). One or more rows → run. Use it to short-circuit when there's nothing to do.
- `load:` is parameterless SQL. Result rows render `prompt:` via mustache:
  - 0 rows → empty context (vars expand to `""`).
  - 1 row → columns bind as scalars (`{{pending}}`). JSON aggregate columns (`json_group_array(...)`) are auto-decoded, so `{{#queue}}…{{/queue}}` iterates over them.
  - >1 rows → bound under `{{#results}}…{{/results}}`.
- `system:` must not contain mustache (`{{...}}`) — it's sent verbatim and cached. Any `{{` in `system:` raises at startup.
- `prompt:` is mustache-rendered before the LLM sees it. `load:` populates the context; without `load:` the prompt is sent as-is.
- `max_turns` caps the tool-use loop. The runner aborts if the model is still calling tools after this many turns.

### Caching + cost telemetry

Sark does cache the `system:` block and tool definitions across turns within a single run, however since most workers are over long cadences (daily / weekly) we won't generally get much in the way of cache benefits.

Every terminal worker state writes one row to a Sark-managed `_worker_log` table in the plugin's own database. Columns:

| column                  | meaning                                         |
| ----------------------- | ----------------------------------------------- |
| `worker_name`           | `"<name>"` from `plugin.yml`                    |
| `model`                 | model id sent to the provider                   |
| `started_at`/`ended_at` | ISO8601 UTC                                     |
| `turns`                 | tool-use loop iterations                        |
| `stop_reason`           | `end_turn` / `max_tokens` / etc                 |
| `input_tokens`          | summed across turns                             |
| `output_tokens`         | summed across turns                             |
| `cache_read_tokens`     | summed across turns                             |
| `cache_creation_tokens` | summed across turns                             |
| `service_tier`          | latest non-nil value reported by the provider   |
| `error`                 | error string on `error`, NULL otherwise         |
| `final_output`          | text from the last assistant turn               |

Runs that the `when:` gate skipped do not log — there's no run to record.

### Triggering a worker manually

Workers normally fire on their `schedule:` cron. To run one on demand — debugging a prompt, smoke-testing a `when:` gate — there are two paths depending on where you sit.

**Developing Sark itself (source tree).** Use the mix task. It boots the app, resolves `<plugin>.<worker>` from the live registry, runs one synchronous pass, and streams the transcript to stdout:

```
SARK_CONFIG=config.yml mix sark.worker kb.dreamer
```

**Developing a plugin against a running Docker instance.** Call into the already-running container:

```
docker exec sark /app/bin/sark rpc 'Sark.CLI.run_worker("kb.dreamer")' && docker logs sark -f --tail 50
```

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

### Scheduling

`schedule:` (5-field cron) is required on every worker. The per-plugin scheduler ticks every minute and spawns a `Task` for each due worker. At most one in-flight run per worker — overlapping ticks are skipped.


## Misc

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

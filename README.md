<img src="./assets/sark.png" alt="SARK" />

A generic SQLite-backed MCP server. Plugins declare their schema (SQL migrations) and a set of canned tools (YAML); Sark exposes each as a typed MCP tool. Agents call the tools, Sark validates parameters, runs the SQL, and renders results.

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
    tools:
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

3. Add the plugin to `plugins:` in `config.yml` (e.g. `kv: /storage/plugins/kv`) and ensure a token is scoped to it.

    ```yaml
    tokens:
      - { name: full,   plugins: "*",                              token: sk-full }
      - { name: kvonly, plugins: [kv],                             token: sk-kv }
      - { name: reader, plugins: [{kv: ["get", "list", "find"]}],  token: sk-ro }
      - { name: mixed,  plugins: [myplugin, {kv: "report_*"}],     token: sk-mix }
    ```

4. Boot Sark. The plugin's database is created and migration 1 is applied.
5. Connect your MCP client, i.e. `claude mcp add --transport http --scope project sark-kv http://localhost:8080/kv/mcp --header "Authorization: Bearer sk-mytoken"`. Clients that can't set custom headers can pass the token as `?token=mytoken` instead.
6. Say something like: `use sark kv, store "x" = 1`, then in a new session `what did i store in sark kv for 'x'?`

### Tips

- **Skills should carry domain knowledge.** Vocabularies, heuristics, conversation flow live in skill prose. Sark tools are the verbs the skill orchestrates.
- **Composite reads.** Bundle nested data using `json_object` / `json_group_array` in SQL. Sark auto-decodes the JSON-string columns; templates iterate them directly.
- **Atomic per tool call.** Each `write: true` tool runs in a transaction; failures roll back automatically.


## Plugin Authoring

Each plugin runs its own MCP router at `/<plugin>/mcp`, so each declared tool is exposed under its name.

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

tools:
  <name>: { ... }

pipelines:
  <name>: { ... }
```

More on all of these below.

## Tools

```yaml
tools:
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
tools:
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

A template format goes inline under the tool:

```yaml
tools:
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
tools:
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

For `write: true` tools, rejects run inside the same transaction as the main statement — preconditions can't race against another writer.

Reject SQL must be plain `SELECT` (no `INSERT`/`UPDATE`/`DELETE`/`WITH`/`PRAGMA`); enforced at load. Same `:bind` params as `sql:`.

### Internal tools (`internal: true`)

A tool marked `internal: true` is **not** registered as an MCP tool. External clients (Claude Code, Cursor, curl) can't see it or call it, and it's omitted from the `sark_catalog` response. Thus, only pipelines can call it.

```yaml
tools:
  flag_reconciled:
    description: Mark a row as reconciled.
    internal: true
    write: true
    returns: count
    params:
      id: { type: integer }
    sql: |
      UPDATE rows SET reconciled_at = datetime('now') WHERE id = :id
```

Use them for things like writing system-only event kinds, flipping server-managed columns, or reading shadow/history tables that shouldn't be part of the public contract.


## Shared Fragments

A `shared:` entry is any reusable subtree — a `params:` block, a `format:`, a reject list, a pipeline's `llm.tools` / `llm.system`, whatever. `@name` substitutes it into **any field of any tool or pipeline**. Example:

```yaml
shared:
  id: { type: text, required: true }   # a single param spec

  pagination:                          # a params sub-block
    limit:  { type: integer, required: false, default: 20 }
    offset: { type: integer, required: false, default: 0 }

  card:                                # a format object
    kind: template
    template: "{{#results}}- {{name}}{{/results}}"

  reader_tools: [list, get]            # an llm tools list

  prefix_rejects:                      # a reject list
    - sql: |
        SELECT 1 FROM tasks WHERE id LIKE :id || '%' AND status='open'
        GROUP BY 1 HAVING COUNT(*) > 1
      message: "ambiguous prefix '{id}' — call resolve first"
    - sql: SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE id LIKE :id || '%')
      message: "no task matches prefix '{id}'"

tools:
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

pipelines:
  janitor:
    description: ...
    schedule: "0 3 * * *"
    steps:
      - llm:
          model: claude-haiku-4-5
          tools: @reader_tools         # @name resolves in pipelines too
          system: ...
          prompt: ...
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

- **`sark_catalog`** returns the live schema and the list of canned tools with their parameter schemas:

  ```json
  {
    "name": "kv",
    "schema": [
      { "type": "table", "name": "kv", "sql": "CREATE TABLE kv (...)" },
      { "type": "index", "name": "kv_updated_at_idx", "sql": "..." }
    ],
    "tools": [
      { "name": "get", "description": "Look up a row by key.", "params": [...], ... }
    ]
  }
  ```

- **`sark_sql(sql)`** runs an arbitrary `SELECT` / `WITH` / `PRAGMA`.

Most plugins should leave `allow_sql: false` and expose only their curated canned tools — those have validated parameter types, structured response formats, and stable contracts the skill is written against. Leaving it enabled with unsupervised agents will probably eventually result in something like `DELETE FROM tasks;`.


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


## Pipelines

A pipeline is a step-based background job owned by a plugin. Steps run in order; the stdout of step N becomes the stdin of step N+1. Pipelines are how a plugin grows ambient behavior: ingest from an external system, fold accumulated state into a summary, post a daily digest to Slack.

### Defining pipelines

Pipelines live under the `pipelines:` key — inline in `plugin.yml` or in any `include:`d file:

```yaml
pipelines:
  ansible_hosts:
    description: Daily ingest of ansible host inventory.
    schedule: "0 3 * * *"                              # optional. 5-field cron. nil = manual-only.
    when: |                                            # optional. Empty result → skip (no log row).
      SELECT 1 WHERE EXISTS (SELECT 1 FROM ingest_queue)
    env: [GITHUB_TOKEN]                                # env var names propagated from sark's env.
    timeout: 600000                                    # optional. Pipeline-level ceiling, ms.
    transactional: false                               # optional. true = whole run in one txn.
    steps:
      - shell: git clone --depth=1 git@github.com:org/automation-mono .
      - shell: python parse_hosts.py                   # outputs {"hosts": [...]}
      - tool: upsert_hosts                             # consumes JSON stdin as params
```

### Step types

- **`shell:`** — `/bin/sh -c <cmd>` in the pipeline's workdir. Stdin = previous step's stdout. Stdout captured for the next step. Non-zero exit aborts the run.
- **`load:`** — read-only SQL. JSON-object stdin parsed as `:name` params. Output is the result rows as a JSON array. Writes are rejected at boot.
- **`tool:`** — call a plugin tool (or a `sark_` built-in) by name. JSON stdin parsed as the tool's params. Output is the tool's response.
- **`llm:`** — agent loop. JSON stdin populates a mustache context for `prompt:`; the loop runs `model:` + `system:` + `tools:` + `max_turns:` until the model stops calling tools. Final assistant text → stdout.

Each step accepts a per-step `timeout:` in long-form:

```yaml
steps:
  - shell: { cmd: gh issue list, timeout: 30000 }
  - load:  { sql: SELECT ..., timeout: 5000 }
  - tool:  { name: upsert_hosts, timeout: 60000 }
  - llm:   { model: ..., prompt: ..., tools: [...], timeout: 120000 }
```

Per-step `timeout:` overrides the pipeline-level one; both default to no ceiling.

### Transactional runs

Set `transactional: true` to wrap the entire run in a single transaction. WIP

### Notes on `shell:`

You will find the published Sark docker image quite lean, so you might be expecting to `shell: jq -r ...` or `shell: gh pr list ...`. To do this, you could ship Debian bookworm compatible binaries with your plugin, or derive your own image from the base:

```
FROM ghcr.io/rfunduk/sark:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl jq python3 gh \
  && rm -rf /var/lib/apt/lists/*
USER sark
```

### Pipe convention

Bytes flow freely between steps. JSON is only required at the `load:` / `tool:` / `llm:` **input** boundary — non-JSON output from `shell:` is fine downstream of another `shell:` but errors if piped into a step that expects JSON. The first step receives empty stdin.

### LLM step

```yaml
- llm:
    model: claude-sonnet-4-6
    tools: [task_with_comments, archive_comments]    # allowlist; names of allowed tools/built-ins.
    max_turns: 16                                    # default 8.
    system: |                                        # required. NO mustache — sent verbatim, cached.
      You roll up task comments into the task summary body.
      Use `sark_patch` to update the body, then `archive_comments` with
      the ids you folded. Stop when every task in the queue is handled.
    prompt: |                                        # required. Mustache-rendered against stdin.
      Tasks with unfolded comments:
      {{#results}}
      - `{{id}}` — {{title}}
      {{/results}}
```

`system:` must not contain mustache (`{{...}}`) — it's sent verbatim and cached. `prompt:` is mustache-rendered using the previous step's JSON stdin as context (an array binds under `{{#results}}`; an object binds at the top level).

`tools:` is a list of allowed tools (including `internal: true`) or built-ins (`sark_patch`, etc). Unknown names raise at runtime.

### Concurrency

A per-pipeline lock arbitrates between the scheduler, `Sark.CLI.run_pipeline`, and the `sark_pipelines_run_now` MCP tool. A cron fire that collides with an in-flight run is dropped (logged as skipped). A manual trigger that collides errors with `busy:`.

### Telemetry

Every run leaves a durable audit trail — per-run header + per-step rows capturing start/end timestamps, status (success / failed / cancelled), trigger (schedule / manual), per-step exit codes (shell), row counts (load / tool), LLM token usage (model, turns, stop reason, input/output/cache tokens, service tier), and the final assistant text. Inspect via the built-in `sark_pipelines_*` tools (see below).

Skipped runs (gated out by `when:`) don't write rows.

### Triggering a pipeline manually

```
# Source tree (streams transcript)
SARK_CONFIG=config.yml mix sark.pipeline kb.dreamer

# Live container (fire-and-forget)
docker exec sark /app/bin/sark rpc 'Sark.CLI.run_pipeline("kb.dreamer")'
docker logs sark -f --tail 50
```

### Built-in observability tools

Every plugin gets these without declaring them.

- **`sark_pipelines_list`** — declared pipelines + last-run summary.
- **`sark_pipelines_log(pipeline, run_id?)`** — full per-step log for one run. `run_id` omitted → latest run for that pipeline.
- **`sark_pipelines_recent(pipeline?, limit?)`** — recent runs across all pipelines or one. Default limit 20.
- **`sark_pipelines_costs(pipeline?, since?)`** — token rollup grouped by pipeline + model (for `llm:` steps). Your skill multiplies by its own price table if desired.
- **`sark_pipelines_run_now(pipeline)`** — fire-and-forget manual trigger.
- **`sark_pipelines_cancel(pipeline, run_id?)`** — best-effort cancel of an in-flight run. Runner peeks between steps; the current step finishes naturally before the run halts.
- **`sark_pipelines_log_prune(pipeline?, older_than)`** — delete run + step rows older than a duration (e.g. `30d`, `6h`). Plugin authors wire their own cleanup pipeline; no built-in retention.


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

Any `UPDATE` to `notes` fires the trigger and lands a snapshot in `notes_history`. Reads against `notes_history` work like any other table — expose them via canned tools.

> Triggers writing to a *different* table (the case above) are safe by default. Triggers that touch the *same* table they fire on (e.g. `AFTER UPDATE ON notes` that updates `notes.updated_at`) need SQLite's `recursive_triggers` PRAGMA disabled (it is, by default) or careful guards to avoid recursion. Easier: bump `updated_at` directly in your `UPDATE` statement instead of via trigger.

You could do bounded retention in the trigger, or add a prune tool the skill can run:

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

defmodule Sark.Plugin.Pipeline do
  @moduledoc """
  Parsed pipeline spec loaded from `plugin.yml`.

  A pipeline is an ordered list of steps that runs on a cron schedule,
  on demand via `mix sark.pipeline`, or — once Phase B observability lands
  — via the `sark_pipelines_run_now` MCP tool.

  Each step is one of:

    * `shell:` — `/bin/sh -c <cmd>` in the pipeline's workdir. Stdin = prev
      step's stdout (raw bytes). Stdout captured for the next step.
    * `load:`  — read-only SQL on the plugin's read pool. Stdin parsed as
      JSON object → params. Output is the result rows as a JSON array.
      Writes are rejected at parse time.
    * `tool:`  — call a tool declared by this plugin (or a built-in like
      `sark_patch`). Stdin parsed as JSON → params. Output is the tool's
      reply text.
    * `llm:`   — agent loop. Stdin parsed as JSON; mustache-rendered into
      `prompt:`. `model:` + `system:` + `tools:` + `max_turns:` mirror
      the former worker spec.

  Pipe convention: bytes flow freely between steps. Only `load:` /
  `tool:` / `llm:` parse stdin as JSON, so non-JSON output from `shell:`
  is fine downstream of another `shell:` but errors if piped into a
  step that expects JSON.

  Fields:

    * `description` — required string
    * `schedule`    — optional 5-field cron. nil = unscheduled (run via
      manual trigger only)
    * `when_sql`    — optional parameterless SELECT. Empty result → run
      is skipped entirely (no log row).
    * `transactional` — bool, default false. **Not yet implemented in
      v1** — set true → parse error at startup.
    * `env`         — list of env-var **names** to propagate from sark's
      own environment into shell steps. Names not present in sark's env
      are passed as empty strings.
    * `workdir`     — optional override for the default
      `/tmp/sark/{plugin}/{pipeline}/{run_id}/` workdir base.
    * `timeout_ms`  — per-pipeline ceiling. nil = no ceiling.
    * `steps`       — ordered list of parsed step specs.
  """

  @enforce_keys [:name, :description, :steps]
  defstruct [
    :name,
    :description,
    :steps,
    schedule: nil,
    when_sql: nil,
    transactional: false,
    env: [],
    workdir: nil,
    timeout_ms: nil
  ]

  @type shell_step :: %{kind: :shell, cmd: String.t(), timeout_ms: pos_integer() | nil}
  @type load_step :: %{
          kind: :load,
          raw_sql: String.t(),
          compiled_sql: String.t(),
          param_order: [atom],
          timeout_ms: pos_integer() | nil
        }
  @type tool_step :: %{kind: :tool, tool: String.t(), timeout_ms: pos_integer() | nil}
  @type llm_step :: %{
          kind: :llm,
          model: String.t(),
          system: String.t() | nil,
          prompt: String.t(),
          tools: [String.t()],
          max_turns: pos_integer(),
          timeout_ms: pos_integer() | nil
        }
  @type step :: shell_step | load_step | tool_step | llm_step

  @type t :: %__MODULE__{
          name: atom,
          description: String.t(),
          steps: [step],
          schedule: Crontab.CronExpression.t() | nil,
          when_sql: String.t() | nil,
          transactional: boolean,
          env: [String.t()],
          workdir: String.t() | nil,
          timeout_ms: pos_integer() | nil
        }

  @default_max_turns 8

  alias Sark.Plugin.Tool.SQL

  @spec parse!(String.t(), map) :: t
  def parse!(name_str, entry) when is_binary(name_str) and is_map(entry) do
    where = "plugin.yml: pipeline #{name_str}"

    description = fetch_string!(entry, "description", where)
    steps_raw = fetch_list!(entry, "steps", where)

    if steps_raw == [] do
      bad!(where, "`steps` must list at least one step")
    end

    steps =
      steps_raw
      |> Enum.with_index()
      |> Enum.map(fn {s, i} -> parse_step!(s, "#{where}.steps[#{i}]") end)

    schedule = parse_schedule!(Map.get(entry, "schedule"), where)
    when_sql = parse_optional_sql!(Map.get(entry, "when"), "when", where)
    transactional = parse_bool!(Map.get(entry, "transactional", false), "transactional", where)

    if transactional do
      bad!(where, "`transactional: true` is not yet implemented in v1")
    end

    env = parse_env!(Map.get(entry, "env", []), where)
    workdir = parse_optional_string!(Map.get(entry, "workdir"), "workdir", where)
    timeout_ms = parse_timeout_ms!(Map.get(entry, "timeout"), where)

    %__MODULE__{
      name: String.to_atom(name_str),
      description: description,
      steps: steps,
      schedule: schedule,
      when_sql: when_sql,
      transactional: transactional,
      env: env,
      workdir: workdir,
      timeout_ms: timeout_ms
    }
  end

  # ── step parsing ───────────────────────────────────────────────────────────

  # Short forms: `- shell: <cmd>`, `- load: <sql>`, `- tool: <name>`.
  # Long forms add config (currently just `timeout:`):
  #
  #     - shell: { cmd: ..., timeout: 30000 }
  #     - load:  { sql: ..., timeout: 5000 }
  #     - tool:  { name: ..., timeout: 60000 }
  #
  # `llm:` is always long-form (model/prompt/tools/etc); `timeout:` joins
  # the existing fields.
  defp parse_step!(map, where) when is_map(map) do
    case Map.keys(map) do
      [k] when k in ~w(shell load tool llm) ->
        parse_step_body!(k, Map.fetch!(map, k), where)

      keys ->
        bad!(
          where,
          "step must declare exactly one of shell/load/tool/llm, got #{inspect(keys)}"
        )
    end
  end

  defp parse_step!(other, where) do
    bad!(where, "step must be a map, got #{inspect(other)}")
  end

  defp parse_step_body!("shell", cmd, where) when is_binary(cmd),
    do: parse_shell_body!(%{"cmd" => cmd}, where)

  defp parse_step_body!("shell", map, where) when is_map(map),
    do: parse_shell_body!(map, where)

  defp parse_step_body!("shell", other, where),
    do: bad!(where, "shell step takes a command string or map, got #{inspect(other)}")

  defp parse_step_body!("load", sql, where) when is_binary(sql),
    do: parse_load_body!(%{"sql" => sql}, where)

  defp parse_step_body!("load", map, where) when is_map(map),
    do: parse_load_body!(map, where)

  defp parse_step_body!("load", other, where),
    do: bad!(where, "load step takes a SQL string or map, got #{inspect(other)}")

  defp parse_step_body!("tool", name, where) when is_binary(name),
    do: parse_tool_body!(%{"name" => name}, where)

  defp parse_step_body!("tool", map, where) when is_map(map),
    do: parse_tool_body!(map, where)

  defp parse_step_body!("tool", other, where),
    do: bad!(where, "tool step takes a tool name string or map, got #{inspect(other)}")

  defp parse_step_body!("llm", entry, where) when is_map(entry) do
    model = fetch_string!(entry, "model", where)
    prompt = fetch_string!(entry, "prompt", where)
    tools = parse_tools!(Map.get(entry, "tools", []), where)
    max_turns = parse_max_turns!(Map.get(entry, "max_turns", @default_max_turns), where)
    timeout_ms = parse_step_timeout!(Map.get(entry, "timeout"), where)

    system =
      case Map.get(entry, "system") do
        nil -> nil
        s when is_binary(s) -> reject_mustache!(s, where)
        other -> bad!(where, "`system` must be a string, got #{inspect(other)}")
      end

    reject_extra_keys!(entry, ~w(model system prompt tools max_turns timeout), where)

    %{
      kind: :llm,
      model: model,
      system: system,
      prompt: prompt,
      tools: tools,
      max_turns: max_turns,
      timeout_ms: timeout_ms
    }
  end

  defp parse_step_body!("llm", other, where) do
    bad!(
      where,
      "llm step takes a map of model/system/prompt/tools/max_turns, got #{inspect(other)}"
    )
  end

  defp parse_shell_body!(map, where) do
    cmd = fetch_string!(map, "cmd", where)
    timeout_ms = parse_step_timeout!(Map.get(map, "timeout"), where)
    reject_extra_keys!(map, ~w(cmd timeout), where)
    %{kind: :shell, cmd: cmd, timeout_ms: timeout_ms}
  end

  defp parse_load_body!(map, where) do
    sql = fetch_string!(map, "sql", where)
    timeout_ms = parse_step_timeout!(Map.get(map, "timeout"), where)
    reject_extra_keys!(map, ~w(sql timeout), where)
    reject_write_sql!(sql, where)
    {compiled, order} = SQL.compile(sql)

    %{
      kind: :load,
      raw_sql: sql,
      compiled_sql: compiled,
      param_order: order,
      timeout_ms: timeout_ms
    }
  end

  defp parse_tool_body!(map, where) do
    name = fetch_string!(map, "name", where)
    timeout_ms = parse_step_timeout!(Map.get(map, "timeout"), where)
    reject_extra_keys!(map, ~w(name timeout), where)
    %{kind: :tool, tool: name, timeout_ms: timeout_ms}
  end

  defp parse_step_timeout!(nil, _where), do: nil
  defp parse_step_timeout!(n, _where) when is_integer(n) and n > 0, do: n

  defp parse_step_timeout!(other, where),
    do:
      bad!(
        where,
        "step `timeout` must be a positive integer (milliseconds), got #{inspect(other)}"
      )

  defp reject_extra_keys!(map, allowed, where) do
    case Map.keys(map) -- allowed do
      [] ->
        :ok

      extras ->
        bad!(
          where,
          "unknown step field(s) #{inspect(extras)} (allowed: #{Enum.join(allowed, ", ")})"
        )
    end
  end

  defp reject_write_sql!(sql, where) do
    if Regex.match?(
         ~r/^\s*(insert|update|delete|replace|drop|create|alter|attach|detach|vacuum|reindex)\b/i,
         sql
       ) do
      bad!(
        where,
        "load step sql must be a read-only SELECT/WITH/PRAGMA, got: #{String.slice(sql, 0, 80)}"
      )
    end
  end

  # ── field helpers ──────────────────────────────────────────────────────────

  defp parse_schedule!(nil, _where), do: nil
  defp parse_schedule!("", _where), do: nil

  defp parse_schedule!(s, where) when is_binary(s) do
    case Crontab.CronExpression.Parser.parse(String.trim(s)) do
      {:ok, expr} ->
        expr

      {:error, reason} ->
        bad!(where, "`schedule` invalid cron expression #{inspect(s)}: #{reason}")
    end
  end

  defp parse_schedule!(other, where),
    do: bad!(where, "`schedule` must be a cron string, got #{inspect(other)}")

  defp parse_optional_sql!(nil, _key, _where), do: nil

  defp parse_optional_sql!(s, _key, _where) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_optional_sql!(other, key, where),
    do: bad!(where, "`#{key}` must be a SQL string, got #{inspect(other)}")

  defp parse_optional_string!(nil, _key, _where), do: nil

  defp parse_optional_string!(s, key, where) when is_binary(s) do
    case String.trim(s) do
      "" -> bad!(where, "`#{key}` must be a non-empty string")
      trimmed -> trimmed
    end
  end

  defp parse_optional_string!(other, key, where),
    do: bad!(where, "`#{key}` must be a string, got #{inspect(other)}")

  defp parse_bool!(v, _key, _where) when is_boolean(v), do: v

  defp parse_bool!(other, key, where),
    do: bad!(where, "`#{key}` must be boolean, got #{inspect(other)}")

  defp parse_env!([], _where), do: []

  defp parse_env!(list, where) when is_list(list) do
    Enum.map(list, fn
      name when is_binary(name) ->
        if Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, name) do
          name
        else
          bad!(where, "env entry `#{name}` must match ^[A-Z_][A-Z0-9_]*$ (env var name)")
        end

      other ->
        bad!(where, "env entries must be strings, got #{inspect(other)}")
    end)
  end

  defp parse_env!(other, where),
    do: bad!(where, "`env` must be a list of env var names, got #{inspect(other)}")

  defp parse_timeout_ms!(nil, _where), do: nil

  defp parse_timeout_ms!(n, _where) when is_integer(n) and n > 0, do: n

  defp parse_timeout_ms!(other, where),
    do: bad!(where, "`timeout` must be a positive integer (milliseconds), got #{inspect(other)}")

  defp parse_tools!(list, where) when is_list(list) do
    Enum.map(list, fn
      t when is_binary(t) and t != "" -> t
      other -> bad!(where, "llm.tools entries must be non-empty strings, got #{inspect(other)}")
    end)
  end

  defp parse_tools!(other, where),
    do: bad!(where, "llm.tools must be a list, got #{inspect(other)}")

  defp parse_max_turns!(n, _where) when is_integer(n) and n > 0, do: n

  defp parse_max_turns!(other, where),
    do: bad!(where, "llm.max_turns must be a positive integer, got #{inspect(other)}")

  defp fetch_string!(entry, key, where) do
    case Map.get(entry, key) do
      v when is_binary(v) and v != "" -> v
      nil -> bad!(where, "missing required field `#{key}`")
      other -> bad!(where, "`#{key}` must be a non-empty string, got #{inspect(other)}")
    end
  end

  defp fetch_list!(entry, key, where) do
    case Map.get(entry, key) do
      list when is_list(list) -> list
      nil -> bad!(where, "missing required field `#{key}`")
      other -> bad!(where, "`#{key}` must be a list, got #{inspect(other)}")
    end
  end

  defp reject_mustache!(text, where) do
    if String.contains?(text, "{{") do
      bad!(
        where,
        "llm `system` must not contain mustache (`{{...}}`) — system blocks are cached verbatim"
      )
    end

    text
  end

  defp bad!(where, msg), do: raise(ArgumentError, message: "#{where}: #{msg}")
end

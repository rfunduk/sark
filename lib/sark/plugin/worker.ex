defmodule Sark.Plugin.Worker do
  @moduledoc """
  Parsed worker spec loaded from `workers.yml`.

  A worker is an internal MCP client driven by a configured Anthropic
  model. v1 has no scheduler — workers are addressable but only fire
  when triggered manually (e.g. `mix sark.worker <plugin>.<name>`). Cron
  + `on_event` triggers are deferred.

  Tool entries in `tools:` are bare names (plugin-local) for v1.
  Cross-plugin `<plugin>.<tool>` is reserved for a later iteration —
  parser accepts the dotted form but the runner rejects it.

  Optional gating + context loading:

    * `when:` — parameterless SQL. Empty result set → worker is skipped
      entirely (no LLM call, no log row). Any row (≥1) → run.
    * `load:` — parameterless SQL. Result rows feed mustache rendering
      of `prompt:`:
        - 0 rows → render with empty context (vars expand to "")
        - 1 row → row's columns bind as scalars (`{{pending}}`); JSON
          aggregate columns auto-decoded so `{{#queue}}…{{/queue}}` works
        - >1 rows → bound under `{{#results}}…{{/results}}`

  `system:` may **not** contain mustache (`{{`). Mustache in `system:`
  defeats the prompt cache and is rejected at parse.
  """

  @enforce_keys [:name, :description, :model, :system, :prompt, :tools, :max_turns]
  defstruct [
    :name,
    :description,
    :model,
    :system,
    :prompt,
    :tools,
    :max_turns,
    when_sql: nil,
    load_sql: nil
  ]

  @type t :: %__MODULE__{
          name: atom,
          description: String.t(),
          model: String.t(),
          system: String.t(),
          prompt: String.t(),
          tools: [String.t()],
          max_turns: pos_integer(),
          when_sql: String.t() | nil,
          load_sql: String.t() | nil
        }

  @default_max_turns 8

  @doc """
  Parse a single entry from `workers.yml` into a `%Worker{}`.
  """
  @spec parse!(String.t(), map) :: t
  def parse!(name_str, entry) when is_binary(name_str) and is_map(entry) do
    where = "workers.yml: #{name_str}"

    description = fetch_string!(entry, "description", where)
    model = fetch_string!(entry, "model", where)
    system = fetch_string!(entry, "system", where) |> reject_mustache!(where)
    prompt = fetch_string!(entry, "prompt", where)
    tools = parse_tools!(Map.get(entry, "tools"), where)
    max_turns = parse_max_turns!(Map.get(entry, "max_turns", @default_max_turns), where)
    when_sql = parse_optional_sql!(Map.get(entry, "when"), "when", where)
    load_sql = parse_optional_sql!(Map.get(entry, "load"), "load", where)

    %__MODULE__{
      name: String.to_atom(name_str),
      description: description,
      model: model,
      system: system,
      prompt: prompt,
      tools: tools,
      max_turns: max_turns,
      when_sql: when_sql,
      load_sql: load_sql
    }
  end

  defp fetch_string!(entry, key, where) do
    case Map.get(entry, key) do
      v when is_binary(v) and v != "" -> v
      nil -> bad!(where, "missing required field `#{key}`")
      other -> bad!(where, "`#{key}` must be a non-empty string, got #{inspect(other)}")
    end
  end

  defp parse_tools!(nil, where), do: bad!(where, "missing required field `tools`")

  defp parse_tools!(list, where) when is_list(list) do
    if list == [] do
      bad!(where, "`tools` must list at least one tool")
    end

    Enum.map(list, fn
      t when is_binary(t) and t != "" -> t
      other -> bad!(where, "tool entries must be non-empty strings, got #{inspect(other)}")
    end)
  end

  defp parse_tools!(other, where),
    do: bad!(where, "`tools` must be a list, got #{inspect(other)}")

  defp parse_max_turns!(n, _where) when is_integer(n) and n > 0, do: n

  defp parse_max_turns!(other, where),
    do: bad!(where, "`max_turns` must be a positive integer, got #{inspect(other)}")

  defp parse_optional_sql!(nil, _key, _where), do: nil

  defp parse_optional_sql!(s, _key, _where) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_optional_sql!(other, key, where),
    do: bad!(where, "`#{key}` must be a SQL string, got #{inspect(other)}")

  defp reject_mustache!(text, where) do
    if String.contains?(text, "{{") do
      bad!(
        where,
        "`system` must not contain mustache (`{{...}}`) — system blocks are cached verbatim"
      )
    end

    text
  end

  defp bad!(where, msg), do: raise(ArgumentError, message: "#{where}: #{msg}")
end

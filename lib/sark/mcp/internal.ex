defmodule Sark.MCP.Internal do
  @moduledoc """
  In-process MCP dispatcher for workers.

  Workers call the same handlers as external HTTP clients but without
  going over the wire — saves bearer-auth ceremony and HTTP overhead
  for v1. Returns a flat `{:ok, text} | {:error, msg}` shape; the
  worker runner threads these back into the LLM loop as `tool_result`
  blocks.

  `tools_for/1` enumerates the tools a plugin exposes, including the
  built-ins gated by `allow_sql` and the always-on `patch_text`. A
  worker's `tools:` allowlist is enforced *outside* this module — the
  dispatcher trusts callers; the runner is the gate.

  v1 is plugin-local: the `plugin` arg is set by the caller (the
  worker's owning plugin). Cross-plugin calls (`<plugin>.<tool>` in
  `tools:`) are reserved for a later iteration.
  """

  alias Sark.MCP.Handlers
  alias Sark.MCP.Registry
  alias Sark.Plugin.Spec

  @builtin_always ~w(patch_text)
  @builtin_allow_sql ~w(catalog sql_query)

  @spec call_tool(String.t(), String.t(), map) :: {:ok, String.t()} | {:error, String.t()}
  def call_tool(plugin, tool_name, params)
      when is_binary(plugin) and is_binary(tool_name) and is_map(params) do
    plugin
    |> dispatch(tool_name, params)
    |> unwrap()
  end

  defp dispatch(plugin, "catalog", params),
    do: Handlers.Catalog.call(plugin, params, nil)

  defp dispatch(plugin, "sql_query", params),
    do: Handlers.SqlQuery.call(plugin, params, nil)

  defp dispatch(plugin, "patch_text", params),
    do: Handlers.PatchText.call(plugin, params, nil)

  defp dispatch(plugin, tool_name, params) do
    Handlers.Query.call(plugin, String.to_atom(tool_name), params, nil)
  end

  defp unwrap({:reply, %{content: content, isError: true}, _session}),
    do: {:error, extract_text(content)}

  defp unwrap({:reply, %{content: content}, _session}),
    do: {:ok, extract_text(content)}

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{type: :text, text: t} -> t
      other -> inspect(other)
    end)
  end

  @doc """
  Build the JSON-schema list of tools available to a worker, derived
  from the plugin spec + the worker's allowlist. Names not registered
  in the plugin (or not enabled by `allow_sql`) raise — caught at
  runner startup, not at LLM-call time.
  """
  @spec tools_for(Spec.t(), [String.t()]) :: [map]
  def tools_for(%Spec{} = spec, allowlist) when is_list(allowlist) do
    available = available_tools(spec)

    Enum.map(allowlist, fn name ->
      case Map.fetch(available, name) do
        {:ok, schema} ->
          schema

        :error ->
          raise ArgumentError,
            message:
              "worker references unknown tool `#{name}` for plugin `#{spec.name}`. Available: #{Map.keys(available) |> Enum.sort() |> Enum.join(", ")}"
      end
    end)
  end

  defp available_tools(%Spec{} = spec) do
    query_tools =
      Enum.into(spec.queries, %{}, fn q ->
        {Atom.to_string(q.name),
         %{
           name: Atom.to_string(q.name),
           description: q.description,
           input_schema: Sark.Plugin.Query.to_json_schema(q)
         }}
      end)

    builtins =
      builtin_specs(spec)
      |> Enum.into(%{}, fn schema -> {schema.name, schema} end)

    Map.merge(query_tools, builtins)
  end

  defp builtin_specs(%Spec{name: plugin, allow_sql: allow_sql}) do
    always =
      Enum.map(@builtin_always, fn name -> builtin_spec(name, plugin) end)

    sql =
      if allow_sql do
        Enum.map(@builtin_allow_sql, fn name -> builtin_spec(name, plugin) end)
      else
        []
      end

    always ++ sql
  end

  defp builtin_spec("patch_text", plugin) do
    %{
      name: "patch_text",
      description:
        "Substring text patch on plugin `#{plugin}`. Replaces every occurrence of `old` with `new` in `col` of the row matching `id`.",
      input_schema: %{
        type: "object",
        required: ["table", "id", "col", "old", "new"],
        properties: %{
          "table" => %{type: "string"},
          "id" => %{},
          "col" => %{type: "string"},
          "old" => %{type: "string"},
          "new" => %{type: "string"}
        }
      }
    }
  end

  defp builtin_spec("catalog", plugin) do
    %{
      name: "catalog",
      description: "Live schema and canned queries for plugin `#{plugin}`.",
      input_schema: %{type: "object", properties: %{}, required: []}
    }
  end

  defp builtin_spec("sql_query", plugin) do
    %{
      name: "sql_query",
      description: "Run an arbitrary SELECT/WITH/PRAGMA against plugin `#{plugin}`.",
      input_schema: %{
        type: "object",
        required: ["sql"],
        properties: %{"sql" => %{type: "string"}}
      }
    }
  end

  @doc """
  Look up a plugin spec from the registry. Wraps Registry.get_spec/1
  with a friendlier error for the runner.
  """
  @spec spec!(String.t()) :: Spec.t()
  def spec!(plugin) do
    case Registry.get_spec(plugin) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, message: "no plugin registered with name `#{plugin}`"
    end
  end
end

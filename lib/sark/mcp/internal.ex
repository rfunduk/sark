defmodule Sark.MCP.Internal do
  @moduledoc """
  In-process MCP dispatcher for workers.

  Workers call the same handlers as external HTTP clients but without
  going over the wire — saves bearer-auth ceremony and HTTP overhead
  for v1. Returns a flat `{:ok, text} | {:error, msg}` shape; the
  worker runner threads these back into the LLM loop as `tool_result`
  blocks.

  `tools_for/2` enumerates the tools a plugin exposes, including the
  built-ins gated by `allow_sql` and the always-on `sark_patch`. A
  worker's allowlist is enforced *outside* this module — the
  dispatcher trusts callers; the runner is the gate.

  v1 is plugin-local: the `plugin` arg is set by the caller (the
  worker's owning plugin). Cross-plugin calls (`<plugin>.<tool>` in
  the allowlist) are reserved for a later iteration.
  """

  alias Sark.MCP.Handlers
  alias Sark.MCP.Registry
  alias Sark.Plugin.Spec

  @builtin_always ~w(sark_patch sark_pipelines_list sark_pipelines_log sark_pipelines_recent sark_pipelines_costs sark_pipelines_run_now sark_pipelines_cancel sark_pipelines_log_prune sark_pipelines_disable sark_pipelines_enable)
  @builtin_allow_sql ~w(sark_catalog sark_sql)

  @spec call_tool(String.t(), String.t(), map, keyword) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_tool(plugin, tool_name, params, opts \\ [])
      when is_binary(plugin) and is_binary(tool_name) and is_map(params) and is_list(opts) do
    plugin
    |> dispatch(tool_name, params, opts)
    |> unwrap()
  end

  # All built-ins thread `opts` (which may carry `conn:` from a
  # transactional pipeline) through their handler. Read builtins route
  # DB.read on the conn; write builtins (`sark_patch`,
  # `sark_pipelines_log_prune`) skip their own DB.txn and run on the
  # caller's conn. `run_now` ignores conn (it spawns a separate run
  # with its own conn lifecycle) but parser-level rejection prevents
  # it from being called from pipelines anyway.
  defp dispatch(plugin, "sark_catalog", params, opts),
    do: Handlers.Catalog.call(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_sql", params, opts),
    do: Handlers.SQL.call(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_patch", params, opts),
    do: Handlers.PatchText.call(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_list", params, opts),
    do: Handlers.Pipelines.list(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_log", params, opts),
    do: Handlers.Pipelines.log(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_recent", params, opts),
    do: Handlers.Pipelines.recent(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_costs", params, opts),
    do: Handlers.Pipelines.costs(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_run_now", params, opts),
    do: Handlers.Pipelines.run_now(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_cancel", params, opts),
    do: Handlers.Pipelines.cancel(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_log_prune", params, opts),
    do: Handlers.Pipelines.prune(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_disable", params, opts),
    do: Handlers.Pipelines.disable(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_pipelines_enable", params, opts),
    do: Handlers.Pipelines.enable(plugin, params, nil, opts)

  defp dispatch(plugin, "sark_embed_status", params, _opts),
    do: Handlers.Embed.status(plugin, params, nil)

  defp dispatch(plugin, "sark_embed_reindex", params, _opts),
    do: Handlers.Embed.reindex(plugin, params, nil)

  defp dispatch(plugin, tool_name, params, opts) do
    Handlers.Tool.call(plugin, String.to_atom(tool_name), params, nil, opts)
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
    tool_specs =
      Enum.into(spec.tools, %{}, fn q ->
        {Atom.to_string(q.name),
         %{
           name: Atom.to_string(q.name),
           description: q.description,
           input_schema: Sark.Plugin.Tool.to_json_schema(q)
         }}
      end)

    builtins =
      builtin_specs(spec)
      |> Enum.into(%{}, fn schema -> {schema.name, schema} end)

    Map.merge(tool_specs, builtins)
  end

  defp builtin_specs(%Spec{allow_sql: allow_sql} = spec) do
    always =
      Enum.map(@builtin_always, fn name -> builtin_spec(name, spec) end)

    sql =
      if allow_sql do
        Enum.map(@builtin_allow_sql, fn name -> builtin_spec(name, spec) end)
      else
        []
      end

    always ++ sql
  end

  defp builtin_spec("sark_patch", %Spec{name: plugin, patchable: patchable}) do
    %{
      name: "sark_patch",
      description: Sark.MCP.Registration.patch_text_description(plugin, patchable),
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

  defp builtin_spec("sark_catalog", %Spec{name: plugin}) do
    %{
      name: "sark_catalog",
      description: "Live schema and canned tools for plugin `#{plugin}`.",
      input_schema: %{type: "object", properties: %{}, required: []}
    }
  end

  defp builtin_spec("sark_sql", %Spec{name: plugin}) do
    %{
      name: "sark_sql",
      description: "Run an arbitrary SELECT/WITH/PRAGMA against plugin `#{plugin}`.",
      input_schema: %{
        type: "object",
        required: ["sql"],
        properties: %{"sql" => %{type: "string"}}
      }
    }
  end

  defp builtin_spec("sark_pipelines_" <> _ = name, %Spec{}) do
    Enum.find(Sark.MCP.Handlers.Pipelines.tool_specs(), &(&1.name == name))
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

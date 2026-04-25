defmodule Sark.MCP.Registration do
  @moduledoc """
  Builds + registers per-plugin MCP tools.

  For each plugin spec:
    * stores spec + queries in `Sark.MCP.Registry`
    * codegens a `Sark.MCP.Generated.<Plugin>` module with one 2-arity
      function per tool (delegates to the appropriate handler)
    * builds tool specs and calls `Phantom.Cache.add_tool/2` against
      `Sark.MCP.Router`

  Idempotent — calling for the same plugin twice clears prior entries
  and re-registers.
  """

  require Logger

  alias Sark.MCP.Registry
  alias Sark.MCP.Router
  alias Sark.Plugin.Query
  alias Sark.Plugin.Spec

  @spec register_plugin!(Spec.t()) :: :ok
  def register_plugin!(%Spec{} = spec) do
    Registry.ensure_table()
    ensure_phantom_initialized()
    Registry.delete_plugin(spec.name)
    Registry.put_spec(spec)

    Enum.each(spec.queries, fn q ->
      Registry.put(spec.name, q.name, q)
    end)

    module = generate_module!(spec)
    Phantom.Cache.add_tool(Router, build_tool_specs(spec, module))

    Logger.info(
      "mcp registration — plugin=#{spec.name} queries=#{length(spec.queries)} +catalog +sql_query"
    )

    :ok
  end

  defp ensure_phantom_initialized do
    Phantom.Cache.register(Router)
  end

  @doc false
  def handler_module(plugin) when is_binary(plugin) do
    Module.concat([Sark.MCP.Generated, Macro.camelize(plugin)])
  end

  defp generate_module!(%Spec{name: plugin, queries: queries}) do
    module = handler_module(plugin)

    query_funcs =
      Enum.map(queries, fn q ->
        fname = String.to_atom("#{plugin}_#{q.name}")
        query_name = q.name

        quote do
          def unquote(fname)(params, session) do
            Sark.MCP.Handlers.Query.call(
              unquote(plugin),
              unquote(query_name),
              params,
              session
            )
          end
        end
      end)

    catalog_fn = String.to_atom("#{plugin}_catalog")
    sql_query_fn = String.to_atom("#{plugin}_sql_query")

    catalog_func =
      quote do
        def unquote(catalog_fn)(params, session) do
          Sark.MCP.Handlers.Catalog.call(unquote(plugin), params, session)
        end
      end

    sql_query_func =
      quote do
        def unquote(sql_query_fn)(params, session) do
          Sark.MCP.Handlers.SqlQuery.call(unquote(plugin), params, session)
        end
      end

    body =
      quote do
        (unquote_splicing(query_funcs ++ [catalog_func, sql_query_func]))
      end

    purge_if_loaded(module)
    Module.create(module, body, Macro.Env.location(__ENV__))
    module
  end

  defp purge_if_loaded(module) do
    if Code.ensure_loaded?(module) do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp build_tool_specs(%Spec{name: plugin, queries: queries}, module) do
    query_specs =
      Enum.map(queries, fn q ->
        %{
          name: "#{plugin}_#{q.name}",
          handler: module,
          function: String.to_atom("#{plugin}_#{q.name}"),
          description: q.description,
          input_schema: Query.to_json_schema(q),
          meta: %{file: __ENV__.file, line: __ENV__.line}
        }
      end)

    catalog_spec = %{
      name: "#{plugin}_catalog",
      handler: module,
      function: String.to_atom("#{plugin}_catalog"),
      description: "Catalog for plugin `#{plugin}` — schema, tables, and canned queries.",
      input_schema: %{type: "object", properties: %{}, required: []},
      meta: %{file: __ENV__.file, line: __ENV__.line}
    }

    sql_query_spec = %{
      name: "#{plugin}_sql_query",
      handler: module,
      function: String.to_atom("#{plugin}_sql_query"),
      description:
        "Run an arbitrary SELECT/WITH/PRAGMA query against plugin `#{plugin}`'s read pool.",
      input_schema: %{
        type: "object",
        required: ["sql"],
        properties: %{"sql" => %{type: "string", description: "Read-only SQL to execute."}}
      },
      meta: %{file: __ENV__.file, line: __ENV__.line}
    }

    query_specs ++ [catalog_spec, sql_query_spec]
  end
end

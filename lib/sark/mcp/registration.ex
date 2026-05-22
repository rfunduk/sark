defmodule Sark.MCP.Registration do
  @moduledoc """
  Builds + registers per-plugin MCP routers and tools.

  For each plugin spec:

    * stores spec + tools in `Sark.MCP.Registry`
    * codegens a handler module `Sark.MCP.Generated.<Plugin>` with one
      2-arity function per tool (delegates to the appropriate handler)
    * codegens a Phantom router module `Sark.MCP.PluginRouter.<Plugin>`
      (just `use Phantom.Router` boilerplate — no compile-time tools)
    * builds tool specs (without a `<plugin>_` prefix) and calls
      `Phantom.Cache.add_tool/2` against the per-plugin router

  Idempotent — calling for the same plugin twice purges the previous
  modules and re-registers.

  The endpoint resolves an incoming `/<plugin>/mcp` request to its
  router via `router_module/1`.
  """

  require Logger

  alias Sark.MCP.Registry
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Tool

  @reserved_names ~w(sark_catalog sark_sql sark_patch sark_pipelines_list sark_pipelines_log sark_pipelines_recent sark_pipelines_costs sark_pipelines_run_now sark_pipelines_cancel sark_pipelines_log_prune sark_pipelines_disable sark_pipelines_enable)a

  @spec register_plugin!(Spec.t()) :: :ok
  def register_plugin!(%Spec{} = spec) do
    check_reserved_names!(spec)
    Registry.ensure_table()
    Registry.delete_plugin(spec.name)
    Registry.put_spec(spec)

    Enum.each(spec.tools, fn q ->
      Registry.put(spec.name, q.name, q)
    end)

    handler = generate_handler!(spec)
    router = generate_router!(spec)

    Phantom.Cache.register(router)
    reset_router_tools(router)
    Phantom.Cache.add_tool(router, build_tool_specs(spec, handler))

    Logger.info(
      "mcp registration — plugin=#{spec.name} tools=#{length(spec.tools)} +sark_catalog +sark_sql +sark_patch +sark_pipelines_*"
    )

    :ok
  end

  @doc """
  Module name of the handler module (functions called by Phantom).
  """
  @spec handler_module(String.t()) :: module
  def handler_module(plugin) when is_binary(plugin) do
    Module.concat([Sark.MCP.Generated, camelize(plugin)])
  end

  @doc """
  Module name of the per-plugin Phantom router. Endpoint resolves
  incoming `/<plugin>/mcp` requests to this module.
  """
  @spec router_module(String.t()) :: module
  def router_module(plugin) when is_binary(plugin) do
    Module.concat([Sark.MCP.PluginRouter, camelize(plugin)])
  end

  defp camelize(plugin), do: Macro.camelize(String.replace(plugin, "-", "_"))

  # Built-in tools (`sark_patch`, `sark_catalog`, `sark_sql`) live alongside
  # plugin-declared tools in the same per-plugin namespace. The `sark_`
  # prefix is reserved — raising on collision keeps a plugin tool from
  # silently shadowing a built-in (or vice versa) depending on
  # registration order.
  defp check_reserved_names!(%Spec{name: plugin, tools: tools}) do
    Enum.each(tools, fn q ->
      if q.name in @reserved_names do
        raise "plugin #{plugin}: tool name `#{q.name}` is reserved (built-in tools: #{Enum.map_join(@reserved_names, ", ", &Atom.to_string/1)})"
      end
    end)
  end

  defp generate_handler!(%Spec{name: plugin, tools: tools}) do
    module = handler_module(plugin)

    tool_funcs =
      tools
      |> Enum.reject(& &1.internal)
      |> Enum.map(fn q ->
        fname = q.name
        tool_name = q.name

        quote do
          def unquote(fname)(params, session) do
            Sark.MCP.Handlers.Tool.call(
              unquote(plugin),
              unquote(tool_name),
              params,
              session
            )
          end
        end
      end)

    catalog_func =
      quote do
        def sark_catalog(params, session) do
          Sark.MCP.Handlers.Catalog.call(unquote(plugin), params, session)
        end
      end

    sql_func =
      quote do
        def sark_sql(params, session) do
          Sark.MCP.Handlers.SQL.call(unquote(plugin), params, session)
        end
      end

    patch_text_func =
      quote do
        def sark_patch(params, session) do
          Sark.MCP.Handlers.PatchText.call(unquote(plugin), params, session)
        end
      end

    pipelines_funcs =
      for {fname, handler_fn} <- [
            sark_pipelines_list: :list,
            sark_pipelines_log: :log,
            sark_pipelines_recent: :recent,
            sark_pipelines_costs: :costs,
            sark_pipelines_run_now: :run_now,
            sark_pipelines_cancel: :cancel,
            sark_pipelines_log_prune: :prune,
            sark_pipelines_disable: :disable,
            sark_pipelines_enable: :enable
          ] do
        quote do
          def unquote(fname)(params, session) do
            Sark.MCP.Handlers.Pipelines.unquote(handler_fn)(
              unquote(plugin),
              params,
              session
            )
          end
        end
      end

    body =
      quote do
        (unquote_splicing(
           tool_funcs ++ [catalog_func, sql_func, patch_text_func] ++ pipelines_funcs
         ))
      end

    purge_if_loaded(module)
    Module.create(module, body, Macro.Env.location(__ENV__))
    module
  end

  defp generate_router!(%Spec{name: plugin}) do
    module = router_module(plugin)

    body =
      quote do
        use Phantom.Router,
          name: unquote(plugin),
          vsn: "0.1.0",
          instructions: "Sark plugin `#{unquote(plugin)}`."

        @impl true
        def connect(session, conn) do
          # Auth + plugin scope already validated upstream by `Sark.AuthPlug`.
          # Resolve per-token tool allow-list against this plugin's tool set
          # and stash on the session — Phantom.Cache.list/3 filters
          # `tools/list` + `tools/call` against `session.allowed_tools`.
          {:ok, Sark.MCP.Registration.apply_token_allowlist(session, conn, unquote(plugin))}
        end
      end

    purge_if_loaded(module)
    Module.create(module, body, Macro.Env.location(__ENV__))
    module
  end

  @doc """
  Compute the per-token tool name allow-list for `plugin` against
  the currently registered tools, and apply it to `session`.

  Skipped (session left untouched) when the conn has no `:token_entry`
  assign — e.g. internal handler calls in tests that bypass `Sark.AuthPlug`.
  """
  @spec apply_token_allowlist(map(), Plug.Conn.t() | map(), String.t()) :: map()
  def apply_token_allowlist(session, %Plug.Conn{} = conn, plugin) do
    case Map.get(conn.assigns, :token_entry) do
      nil ->
        session

      entry ->
        names =
          Phantom.Cache.list(nil, router_module(plugin), :tools)
          |> Enum.map(& &1.name)

        case Sark.AuthRegistry.tool_allowlist(entry, plugin, names) do
          :all -> session
          list when is_list(list) -> %{session | allowed_tools: list}
        end
    end
  end

  def apply_token_allowlist(session, _other, _plugin), do: session

  defp purge_if_loaded(module) do
    if Code.ensure_loaded?(module) do
      :code.purge(module)
      :code.delete(module)
    end
  end

  # `Phantom.Cache.register/1` only seeds the per-router persistent_term
  # if it's uninitialized. On hot reload we must clear the existing tool
  # list explicitly, otherwise stale tools from a previous registration
  # bleed through.
  defp reset_router_tools(router) do
    :persistent_term.put({Phantom, router, :tools}, [])
  end

  defp build_tool_specs(
         %Spec{name: plugin, tools: tools, allow_sql: allow_sql, patchable: patchable},
         handler
       ) do
    tool_specs =
      tools
      |> Enum.reject(& &1.internal)
      |> Enum.map(fn q ->
        %{
          name: Atom.to_string(q.name),
          handler: handler,
          function: q.name,
          description: q.description,
          input_schema: Tool.to_json_schema(q),
          meta: %{file: __ENV__.file, line: __ENV__.line}
        }
      end)

    sql_specs =
      if allow_sql do
        [
          %{
            name: "sark_catalog",
            handler: handler,
            function: :sark_catalog,
            description:
              "Live schema (from sqlite_master) and canned tools for plugin `#{plugin}`.",
            input_schema: %{type: "object", properties: %{}, required: []},
            meta: %{file: __ENV__.file, line: __ENV__.line}
          },
          %{
            name: "sark_sql",
            handler: handler,
            function: :sark_sql,
            description:
              "Run an arbitrary SELECT/WITH/PRAGMA query against plugin `#{plugin}`'s read pool.",
            input_schema: %{
              type: "object",
              required: ["sql"],
              properties: %{"sql" => %{type: "string", description: "Read-only SQL to execute."}}
            },
            meta: %{file: __ENV__.file, line: __ENV__.line}
          }
        ]
      else
        []
      end

    patch_text_spec = %{
      name: "sark_patch",
      handler: handler,
      function: :sark_patch,
      description: patch_text_description(plugin, patchable),
      input_schema: %{
        type: "object",
        required: ["table", "id", "col", "old", "new"],
        properties: %{
          "table" => %{type: "string", description: "Table name (identifier)."},
          "id" => %{description: "Row id (integer or string)."},
          "col" => %{type: "string", description: "Column name (identifier)."},
          "old" => %{type: "string", description: "Substring to find."},
          "new" => %{type: "string", description: "Replacement string."}
        }
      },
      meta: %{file: __ENV__.file, line: __ENV__.line}
    }

    pipelines_specs =
      Enum.map(Sark.MCP.Handlers.Pipelines.tool_specs(), fn ts ->
        %{
          name: ts.name,
          handler: handler,
          function: String.to_atom(ts.name),
          description: ts.description,
          input_schema: ts.input_schema,
          meta: %{file: __ENV__.file, line: __ENV__.line}
        }
      end)

    tool_specs ++ sql_specs ++ [patch_text_spec] ++ pipelines_specs
  end

  @doc false
  # Tool description is built dynamically so the agent sees the
  # plugin's `patchable:` allow-list up front and won't waste calls
  # probing for paths that will be rejected.
  def patch_text_description(plugin, patchable) when is_map(patchable) do
    base =
      "Substring text patch on plugin `#{plugin}`. " <>
        "Reads `col` from `table` where id matches; replaces every occurrence " <>
        "of `old` with `new`. Token-saver vs. re-emitting full bodies. "

    if patchable == %{} do
      base <>
        "No patchable fields configured for plugin `#{plugin}` — every call will be rejected. " <>
        "Plugin author must add a `patchable:` block to plugin.yml to opt fields in."
    else
      paths =
        patchable
        |> Enum.flat_map(fn {t, cols} -> Enum.map(cols, &"#{t}.#{&1}") end)
        |> Enum.sort()
        |> Enum.join(", ")

      base <> "Patchable: #{paths}."
    end
  end
end

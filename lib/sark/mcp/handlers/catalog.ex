defmodule Sark.MCP.Handlers.Catalog do
  @moduledoc """
  Per-plugin catalog handler. Returns the live schema (read from
  `sqlite_master`) and the list of canned queries with their MCP-relevant
  metadata as a structured JSON document.

  Schema reflects the post-migration state of the DB — `ALTER TABLE`
  outcomes, dropped columns, etc. Internal tables (`sqlite_*`,
  `_sark_*`) are filtered out.

  Only registered when the plugin's `plugin.yml` sets `allow_sql: true`.
  """

  require Phantom.Tool, as: Tool

  alias Sark.MCP.Registry
  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Query

  @spec call(String.t(), map, term) :: {:reply, map, term}
  def call(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_catalog", params, fn ->
      do_call(plugin, params, session)
    end)
  end

  defp do_call(plugin, _params, session) do
    case lookup_spec(plugin) do
      nil ->
        {:reply, Tool.error("no such plugin: #{plugin}"), session}

      spec ->
        queries =
          plugin
          |> Registry.list_for_plugin()
          |> Enum.reject(& &1.internal)

        doc = %{
          name: spec.name,
          schema: live_schema(plugin),
          queries: Enum.map(queries, &query_to_map/1)
        }

        {:reply, Tool.text(doc), session}
    end
  end

  defp live_schema(plugin) do
    sql = """
    SELECT type, name, sql
    FROM sqlite_master
    WHERE sql IS NOT NULL
      AND name NOT LIKE 'sqlite_%'
      AND name NOT LIKE '_sark_%'
    ORDER BY CASE type
               WHEN 'table' THEN 0
               WHEN 'view' THEN 1
               WHEN 'index' THEN 2
               WHEN 'trigger' THEN 3
             END, name
    """

    case DB.read(plugin, sql, []) do
      {:ok, _cols, rows} ->
        Enum.map(rows, fn %{"type" => type, "name" => name, "sql" => ddl} ->
          %{type: type, name: name, sql: ddl}
        end)

      _ ->
        []
    end
  end

  defp query_to_map(%Query{} = q) do
    %{
      name: Atom.to_string(q.name),
      description: q.description,
      returns: Atom.to_string(q.returns),
      write: q.write,
      params: Enum.map(q.params, &param_to_map/1),
      format: format_to_string(q.format)
    }
  end

  defp param_to_map(p) do
    base = %{
      name: Atom.to_string(p.name),
      type: Atom.to_string(p.type),
      required: p.required
    }

    base
    |> maybe_put(:default, p.default, p.default != :none)
    |> maybe_put(:enum, p.enum, p.enum != nil)
    |> maybe_put(:description, p.description, p.description != nil)
  end

  defp maybe_put(map, _k, _v, false), do: map
  defp maybe_put(map, k, v, true), do: Map.put(map, k, v)

  defp format_to_string(:json), do: "json"
  defp format_to_string(:table), do: "table"
  defp format_to_string(:list), do: "list"
  defp format_to_string({:template, _}), do: "template"

  defp lookup_spec(plugin) do
    case Registry.get_spec(plugin) do
      {:ok, spec} -> spec
      :error -> nil
    end
  end
end

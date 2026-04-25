defmodule Sark.MCP.Handlers.Catalog do
  @moduledoc """
  Per-plugin catalog handler. Returns the plugin's schema.sql, metadata,
  and the list of canned queries (with descriptions, return shape, params,
  and format) as a structured JSON document.

  Each plugin gets a `<plugin>_catalog` tool that delegates here.
  """

  require Phantom.Tool, as: Tool

  alias Sark.MCP.Registry
  alias Sark.Plugin.Query

  @spec call(String.t(), map, term) :: {:reply, map, term}
  def call(plugin, _params, session) do
    case lookup_spec(plugin) do
      nil ->
        {:reply, Tool.error("no such plugin: #{plugin}"), session}

      spec ->
        queries = Registry.list_for_plugin(plugin)

        doc = %{
          name: spec.name,
          title: Map.get(spec.metadata, "title"),
          description: Map.get(spec.metadata, "description"),
          schema_sql: spec.schema_sql,
          tables: Map.get(spec.metadata, "tables", %{}),
          queries: Enum.map(queries, &query_to_map/1)
        }

        {:reply, Tool.text(doc), session}
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

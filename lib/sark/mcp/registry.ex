defmodule Sark.MCP.Registry do
  @moduledoc """
  ETS-backed registry of plugin tools, keyed by `{plugin, tool_name}`.

  Created lazily — `ensure_table/0` is idempotent so callers don't need
  to coordinate a startup process. Used by the tool handler to look up
  the parsed `%Sark.Plugin.Tool{}` for an incoming MCP tool call, and
  by the catalog handler to enumerate a plugin's tools.
  """

  alias Sark.Plugin.Spec
  alias Sark.Plugin.Tool

  @table :sark_tool_registry
  @specs :sark_plugin_specs

  @spec ensure_table() :: :ok
  def ensure_table do
    ensure_named_table(@table)
    ensure_named_table(@specs)
    :ok
  end

  defp ensure_named_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  @spec put(String.t(), atom, Tool.t()) :: :ok
  def put(plugin, name, %Tool{} = q) do
    :ets.insert(@table, {{plugin, name}, q})
    :ok
  end

  @spec get(String.t(), atom) :: {:ok, Tool.t()} | :error
  def get(plugin, name) do
    case :ets.lookup(@table, {plugin, name}) do
      [{_, q}] -> {:ok, q}
      [] -> :error
    end
  end

  @spec list_for_plugin(String.t()) :: [Tool.t()]
  def list_for_plugin(plugin) do
    :ets.match_object(@table, {{plugin, :_}, :_})
    |> Enum.map(fn {_, q} -> q end)
    |> Enum.sort_by(& &1.name)
  end

  @spec delete_plugin(String.t()) :: :ok
  def delete_plugin(plugin) do
    :ets.match_delete(@table, {{plugin, :_}, :_})
    :ets.delete(@specs, plugin)
    :ok
  end

  @spec put_spec(Spec.t()) :: :ok
  def put_spec(%Spec{name: name} = spec) do
    :ets.insert(@specs, {name, spec})
    :ok
  end

  @spec get_spec(String.t()) :: {:ok, Spec.t()} | :error
  def get_spec(plugin) do
    case :ets.lookup(@specs, plugin) do
      [{_, spec}] -> {:ok, spec}
      [] -> :error
    end
  end
end

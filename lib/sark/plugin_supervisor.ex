defmodule Sark.PluginSupervisor do
  @moduledoc """
  Per-plugin DynamicSupervisor. M1 stub — plugin loader lands in M2.
  """

  use DynamicSupervisor

  def start_link(plugin_paths) when is_list(plugin_paths) do
    DynamicSupervisor.start_link(__MODULE__, plugin_paths, name: __MODULE__)
  end

  @impl true
  def init(_plugin_paths) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

defmodule Sark.PluginSupervisor do
  @moduledoc """
  Top-level plugin supervisor. One child per configured plugin path
  (`Sark.Plugin`); `:one_for_one` so a crashing plugin doesn't take
  the rest down.

  Plugins are loaded eagerly at boot. With `hot_reload: true`, each
  `Sark.Plugin` also runs a `Sark.Plugin.Watcher` that re-registers
  MCP tools on `queries.yml`/`metadata.yml` edits.
  """

  use Supervisor
  require Logger

  alias Sark.Plugin
  alias Sark.Plugin.Loader

  @type opts :: [
          plugins: %{String.t() => String.t()},
          data_dir: String.t(),
          hot_reload: boolean()
        ]

  @spec start_link(opts) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    plugins = Keyword.fetch!(opts, :plugins)
    data_dir = Keyword.fetch!(opts, :data_dir)
    hot_reload = Keyword.get(opts, :hot_reload, false)

    children =
      Enum.map(plugins, fn {name, path} ->
        spec = Loader.load!(name, path)

        Supervisor.child_spec(
          {Plugin, spec: spec, data_dir: data_dir, hot_reload: hot_reload},
          id: {Plugin, spec.name}
        )
      end)

    Logger.info("plugin supervisor — loading #{length(children)} plugin(s)")

    Supervisor.init(children, strategy: :one_for_one)
  end
end

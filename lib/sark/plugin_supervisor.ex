defmodule Sark.PluginSupervisor do
  @moduledoc """
  Top-level plugin supervisor. One child per configured plugin path
  (`Sark.Plugin`); `:one_for_one` so a crashing plugin doesn't take
  the rest down.

  Plugins are loaded eagerly at boot. Plugin file edits require a
  process restart to take effect (forward-only migrations + cold-boot
  registration).
  """

  use Supervisor
  require Logger

  alias Sark.Plugin
  alias Sark.Plugin.Loader

  @type opts :: [
          plugins: %{String.t() => String.t()},
          data_dir: String.t()
        ]

  @spec start_link(opts) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    plugins = Keyword.fetch!(opts, :plugins)
    data_dir = Keyword.fetch!(opts, :data_dir)

    children =
      Enum.map(plugins, fn {name, path} ->
        spec = Loader.load!(name, path)

        Supervisor.child_spec(
          {Plugin, spec: spec, data_dir: data_dir},
          id: {Plugin, spec.name}
        )
      end)

    Logger.info("plugin supervisor — loading #{length(children)} plugin(s)")

    Supervisor.init(children, strategy: :one_for_one)
  end
end

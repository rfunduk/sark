defmodule Sark.PluginSupervisor do
  @moduledoc """
  Top-level plugin supervisor. One child per configured plugin path
  (`Sark.Plugin`); `:one_for_one` so a crashing plugin doesn't take
  the rest down.

  M2 loads plugins eagerly at boot. Hot reload is deferred — restart
  the OTP application to pick up plugin changes.
  """

  use Supervisor
  require Logger

  alias Sark.Plugin
  alias Sark.Plugin.Loader

  @type opts :: [plugin_paths: [String.t()], data_dir: String.t()]

  @spec start_link(opts) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    plugin_paths = Keyword.fetch!(opts, :plugin_paths)
    data_dir = Keyword.fetch!(opts, :data_dir)

    children =
      Enum.map(plugin_paths, fn path ->
        spec = Loader.load!(path)

        Supervisor.child_spec(
          {Plugin, spec: spec, data_dir: data_dir},
          id: {Plugin, spec.name}
        )
      end)

    Logger.info("plugin supervisor — loading #{length(children)} plugin(s)")

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Sark.Plugin do
  @moduledoc """
  Per-plugin supervisor.

  Owns one plugin's lifecycle: applies any unapplied migrations against
  `{data_dir}/{name}.db` (creating the file + enabling WAL on first run),
  then starts the writer + reader DBConnection pools.

  Migrations run before any pool is started — the supervisor's start
  callback opens a one-shot raw connection, runs `Sark.Plugin.Migrations`,
  and only then returns the child spec list. A migration failure aborts
  plugin startup, which keeps a busted plugin from poisoning the rest
  of the supervision tree (the parent `Sark.PluginSupervisor` is
  `:one_for_one`, so other plugins continue).
  """

  use Supervisor
  require Logger

  alias Sark.MCP.Registration
  alias Sark.Plugin.DB
  alias Sark.Plugin.Migrations
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Watcher

  @type opts :: [spec: Spec.t(), data_dir: String.t(), hot_reload: boolean()]

  @spec start_link(opts) :: Supervisor.on_start()
  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)
    Supervisor.start_link(__MODULE__, opts, name: registered_name(spec.name))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin_name), do: :"sark_plugin_#{plugin_name}"

  @impl true
  def init(opts) do
    %Spec{} = spec = Keyword.fetch!(opts, :spec)
    data_dir = Keyword.fetch!(opts, :data_dir)
    hot_reload = Keyword.get(opts, :hot_reload, false)

    db_path = Path.join(data_dir, "#{spec.name}.db")
    File.mkdir_p!(Path.dirname(db_path))

    :ok = Migrations.apply!(spec.name, db_path, spec.migrations)
    Registration.register_plugin!(spec)

    Logger.info("plugin #{spec.name} ready — db=#{db_path}")

    pool_children = DB.pool_children(spec.name, db_path)

    watcher_child =
      if hot_reload do
        [{Watcher, plugin_name: spec.name, plugin_dir: spec.dir}]
      else
        []
      end

    Supervisor.init(pool_children ++ watcher_child, strategy: :rest_for_one)
  end
end

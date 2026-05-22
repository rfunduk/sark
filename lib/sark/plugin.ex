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

  @type opts :: [spec: Spec.t(), data_dir: String.t()]

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

    db_path = Path.join(data_dir, "#{spec.name}.db")
    File.mkdir_p!(Path.dirname(db_path))

    :ok = apply_internal_migrations!(spec.name, DB.sark_db_path(db_path))
    :ok = Migrations.apply!(spec.name, db_path, spec.migrations)
    Registration.register_plugin!(spec)

    Logger.info("plugin #{spec.name} ready — db=#{db_path}")

    pool_children = DB.pool_children(spec.name, db_path)
    scheduler_child = [{Sark.Pipeline.Scheduler, spec: spec}]

    Supervisor.init(
      pool_children ++ scheduler_child,
      strategy: :rest_for_one
    )
  end

  # Apply the sark-internal migration track against the plugin's sark
  # DB. Migrations ship in `priv/internal_migrations/` and are
  # version-locked to the sark release. Sark.Migrations.apply! opens
  # the DB in readwrite mode, creating the file on first boot, sets
  # WAL, ensures the tracker, then applies any pending migrations.
  defp apply_internal_migrations!(plugin_name, sark_db_path) do
    mig_dir = Path.join(:code.priv_dir(:sark), "internal_migrations")
    label = "sark internal (#{plugin_name})"

    Sark.Migrations.apply!(
      source_label: label,
      db_path: sark_db_path,
      migrations: Sark.Migrations.discover!(mig_dir, label),
      tracker_table: "_migrations"
    )
  end
end

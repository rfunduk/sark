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
  alias Sark.Plugin.EmbedMigrator
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

    :ok = apply_internal_sark_db_migrations!(spec.name, DB.sark_db_path(db_path))
    :ok = Migrations.apply!(spec.name, db_path, spec.migrations)
    :ok = apply_internal_plugin_db_migrations!(spec.name, db_path)
    :ok = maybe_apply_embed_migrations!(spec, db_path)
    Registration.register_plugin!(spec)

    Logger.info("plugin #{spec.name} ready — db=#{db_path}")

    pool_children = DB.pool_children(spec.name, db_path, pool_opts(spec))
    log_writer_child = [{Sark.Pipeline.LogWriter, plugin: spec.name}]
    scheduler_child = [{Sark.Pipeline.Scheduler, spec: spec}]
    embed_drain_child = embed_drain_child(spec)

    Supervisor.init(
      pool_children ++ log_writer_child ++ scheduler_child ++ embed_drain_child,
      strategy: :rest_for_one
    )
  end

  defp embed_drain_child(%Spec{embed: embed}) when map_size(embed) == 0, do: []

  defp embed_drain_child(%Spec{name: name, embed: embed}) do
    embedder = Sark.Boot.load_config!().embedder

    [
      {Sark.Plugin.EmbedDrain, [plugin: name, embed: embed, embedder: embedder]}
    ]
  end

  # Sark-managed migrations against the plugin's *sark DB* — pipeline
  # log, scheduler state, etc. Lives in `priv/internal_migrations/`,
  # version-locked to the sark release. Tracker: `_migrations` in the
  # sark DB.
  defp apply_internal_sark_db_migrations!(plugin_name, sark_db_path) do
    mig_dir = Path.join(:code.priv_dir(:sark), "internal_migrations")
    label = "sark internal sark-db (#{plugin_name})"

    Sark.Migrations.apply!(
      source_label: label,
      db_path: sark_db_path,
      migrations: Sark.Migrations.discover!(mig_dir, label),
      tracker_table: "_migrations"
    )
  end

  # Sark-managed migrations against the plugin's *plugin DB* — sark
  # owns these tables but they sit alongside plugin data so triggers
  # can write atomically with plugin writes (e.g. `_embed_queue`).
  # Lives in `priv/plugin_migrations/`, version-locked to the sark
  # release. Tracker: `_sark_internal_migrations` in the plugin DB
  # (distinct from `_sark_migrations`, the plugin-author track).
  defp apply_internal_plugin_db_migrations!(plugin_name, db_path) do
    mig_dir = Path.join(:code.priv_dir(:sark), "plugin_migrations")
    label = "sark internal plugin-db (#{plugin_name})"

    Sark.Migrations.apply!(
      source_label: label,
      db_path: db_path,
      migrations: Sark.Migrations.discover!(mig_dir, label),
      tracker_table: "_sark_internal_migrations"
    )
  end

  # No-op when the plugin doesn't declare `embed:`. Otherwise hands
  # off to EmbedMigrator (which itself validates that an `embedder:`
  # is configured and raises otherwise).
  defp maybe_apply_embed_migrations!(%Spec{embed: embed}, _db_path) when map_size(embed) == 0,
    do: :ok

  defp maybe_apply_embed_migrations!(%Spec{name: name, embed: embed}, db_path) do
    embedder = Sark.Boot.load_config!().embedder
    EmbedMigrator.apply!(name, db_path, embed, embedder, SqliteVec.path())
  end

  defp pool_opts(%Spec{embed: embed, db: db}) when map_size(embed) == 0 do
    db_opts(db)
  end

  defp pool_opts(%Spec{db: db}) do
    [data_load_extensions: [SqliteVec.path()]] ++ db_opts(db)
  end

  defp db_opts(db) when is_map(db) do
    Enum.flat_map([:readers, :cache_size, :mmap_size], fn key ->
      case Map.fetch(db, key) do
        {:ok, v} -> [{key, v}]
        :error -> []
      end
    end)
  end
end

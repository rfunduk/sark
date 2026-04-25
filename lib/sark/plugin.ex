defmodule Sark.Plugin do
  @moduledoc """
  Per-plugin supervisor.

  Owns one plugin's lifecycle: applies `schema.sql` idempotently against
  `{data_dir}/{name}.db` (creating the file + enabling WAL on first run),
  then starts the writer + reader DBConnection pools.

  Schema apply happens before any pool is started — the supervisor's
  start callback opens a one-shot raw connection, runs the schema, and
  only then returns the child spec list. A schema-apply failure aborts
  plugin startup, which keeps a busted plugin from poisoning the rest
  of the supervision tree (the parent `Sark.PluginSupervisor` is
  `:one_for_one`, so other plugins continue).
  """

  use Supervisor
  require Logger

  alias Exqlite.Sqlite3
  alias Sark.Plugin.DB
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

    apply_schema!(db_path, spec)

    Logger.info("plugin #{spec.name} ready — db=#{db_path}")

    children = DB.pool_children(spec.name, db_path)
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp apply_schema!(db_path, %Spec{name: name, schema_sql: sql}) do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys = ON")

      case Sqlite3.execute(db, sql) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "plugin #{name}: schema.sql failed: #{inspect(reason)}"
      end
    after
      Sqlite3.close(db)
    end
  end
end

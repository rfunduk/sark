defmodule Sark.Plugin.Migrations do
  @moduledoc """
  Forward-only SQL migrations per plugin.

  Each plugin ships a `migrations/` directory of numbered SQL files
  (`0001_initial.sql`, `0002_add_x.sql`, …). On boot, sark applies
  any not-yet-applied migrations in order, tracking the applied set
  in a per-plugin `_sark_migrations` table.

  Rules:
    * file versions must be contiguous from 1 (no gaps in the source set)
    * applied set must be a prefix of the file set (no missing-but-applied)
    * each migration runs in its own transaction; failure leaves it unapplied
    * forward-only — no down migrations
    * never edit an applied migration; sark doesn't enforce, contract only

  Apply delegates to `Sark.Migrations` — the shared runner used by
  both this plugin-migration track and (forthcoming) the sark-internal
  migration track.
  """

  alias Exqlite.Sqlite3

  @migration_re ~r/^(\d+)_([a-z0-9_]+)\.sql$/

  @doc """
  Discover migrations on disk. Returns `[%{version, name, path, sql}]`
  sorted ascending by version. Raises on bad filenames or version gaps.
  """
  @spec discover!(Path.t()) :: [Sark.Migrations.migration()]
  def discover!(plugin_dir) do
    mig_dir = Path.join(plugin_dir, "migrations")

    unless File.dir?(mig_dir) do
      raise "plugin #{plugin_dir}: missing required `migrations/` directory"
    end

    files =
      mig_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".sql"))
      |> Enum.sort()

    if files == [] do
      raise "plugin #{plugin_dir}: `migrations/` is empty (need at least 0001_*.sql)"
    end

    parsed =
      Enum.map(files, fn fname ->
        case Regex.run(@migration_re, fname) do
          [_, ver_str, name] ->
            ver = String.to_integer(ver_str)
            path = Path.join(mig_dir, fname)
            %{version: ver, name: name, path: path, sql: File.read!(path)}

          _ ->
            raise "plugin #{plugin_dir}: bad migration filename `#{fname}` " <>
                    "(expected `<version>_<name>.sql`, e.g. `0001_initial.sql`)"
        end
      end)
      |> Enum.sort_by(& &1.version)

    versions = Enum.map(parsed, & &1.version)
    expected = Enum.to_list(1..length(versions))

    if versions != expected do
      raise "plugin #{plugin_dir}: migration versions must be contiguous from 1, " <>
              "got #{inspect(versions)} (expected #{inspect(expected)})"
    end

    parsed
  end

  @doc """
  Apply any unapplied migrations against the DB at `db_path`. Ensures
  sark-managed system tables (`_pipeline_log`, `_pipeline_step_log`)
  exist, then delegates the migration loop to `Sark.Migrations`.
  """
  @spec apply!(String.t(), Path.t(), [Sark.Migrations.migration()]) :: :ok
  def apply!(plugin_name, db_path, migrations) do
    :ok = ensure_system_tables!(db_path)

    Sark.Migrations.apply!(
      source_label: "plugin #{plugin_name}",
      db_path: db_path,
      migrations: migrations,
      tracker_table: "_sark_migrations"
    )
  end

  # Sark-owned tables created idempotently before plugin migrations
  # apply. Slated to move into a sark-internal migration ladder; kept here
  # until that lands so M2 observability keeps working unchanged.
  defp ensure_system_tables!(db_path) do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys = ON")

      with :ok <-
             Sqlite3.execute(db, """
               CREATE TABLE IF NOT EXISTS _pipeline_log (
                 run_id       TEXT    PRIMARY KEY,
                 pipeline     TEXT    NOT NULL,
                 started_at   TEXT    NOT NULL,
                 finished_at  TEXT    NOT NULL,
                 status       TEXT    NOT NULL,
                 error        TEXT,
                 triggered_by TEXT    NOT NULL
               );
             """),
           :ok <-
             Sqlite3.execute(
               db,
               "CREATE INDEX IF NOT EXISTS _pipeline_log_started_at ON _pipeline_log(started_at)"
             ),
           :ok <-
             Sqlite3.execute(
               db,
               "CREATE INDEX IF NOT EXISTS _pipeline_log_pipeline ON _pipeline_log(pipeline)"
             ),
           :ok <-
             Sqlite3.execute(db, """
               CREATE TABLE IF NOT EXISTS _pipeline_step_log (
                 id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                 run_id                TEXT    NOT NULL,
                 step_index            INTEGER NOT NULL,
                 step_type             TEXT    NOT NULL,
                 started_at            TEXT    NOT NULL,
                 finished_at           TEXT    NOT NULL,
                 status                TEXT    NOT NULL,
                 error                 TEXT,
                 exit_code             INTEGER,
                 stdout_bytes          INTEGER,
                 stderr_tail           TEXT,
                 tool_name             TEXT,
                 row_count             INTEGER,
                 model                 TEXT,
                 turns                 INTEGER,
                 stop_reason           TEXT,
                 input_tokens          INTEGER,
                 output_tokens         INTEGER,
                 cache_read_tokens     INTEGER,
                 cache_creation_tokens INTEGER,
                 service_tier          TEXT,
                 final_output          TEXT,
                 FOREIGN KEY (run_id) REFERENCES _pipeline_log(run_id) ON DELETE CASCADE
               );
             """),
           :ok <-
             Sqlite3.execute(
               db,
               "CREATE INDEX IF NOT EXISTS _pipeline_step_log_run_id ON _pipeline_step_log(run_id)"
             ) do
        :ok
      end
    after
      Sqlite3.close(db)
    end
  end
end

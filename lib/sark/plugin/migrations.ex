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
  """

  require Logger

  alias Exqlite.Sqlite3

  @migration_re ~r/^(\d+)_[a-z0-9_]+\.sql$/

  @doc """
  Discover migrations on disk. Returns `[%{version, path, sql}]` sorted
  ascending by version. Raises on bad filenames or version gaps.
  """
  @spec discover!(Path.t()) :: [%{version: pos_integer, path: Path.t(), sql: String.t()}]
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
          [_, ver_str] ->
            ver = String.to_integer(ver_str)
            path = Path.join(mig_dir, fname)
            %{version: ver, path: path, sql: File.read!(path)}

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
  Apply any unapplied migrations against the DB at `db_path`. Sets
  WAL + foreign_keys on the connection before applying. Idempotent —
  re-runs are no-ops once the applied set matches the file set.
  """
  @spec apply!(String.t(), Path.t(), [%{version: pos_integer, path: Path.t(), sql: String.t()}]) ::
          :ok
  def apply!(plugin_name, db_path, migrations) do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys = ON")
      :ok = ensure_table(db)
      :ok = ensure_system_tables(db)

      applied = applied_versions(db)
      file_versions = Enum.map(migrations, & &1.version)

      validate_applied_is_prefix!(plugin_name, applied, file_versions)

      pending = Enum.reject(migrations, fn m -> MapSet.member?(applied, m.version) end)

      Enum.each(pending, fn m -> apply_one!(db, plugin_name, m) end)

      :ok
    after
      Sqlite3.close(db)
    end
  end

  defp ensure_table(db) do
    Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS _sark_migrations (
        version    INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      );
    """)
  end

  # Sark-owned tables (prefixed with `_`) created idempotently before
  # plugin migrations run. Forward-compatible additions only: each new
  # column would need a real migration ladder; we don't have one yet.
  defp ensure_system_tables(db) do
    with :ok <-
           Sqlite3.execute(db, """
             CREATE TABLE IF NOT EXISTS _worker_log (
               id                    INTEGER PRIMARY KEY AUTOINCREMENT,
               worker_name           TEXT    NOT NULL,
               provider              TEXT,
               model                 TEXT,
               started_at            TEXT    NOT NULL,
               ended_at              TEXT    NOT NULL,
               turns                 INTEGER,
               stop_reason           TEXT    NOT NULL,
               input_tokens          INTEGER,
               output_tokens         INTEGER,
               cache_read_tokens     INTEGER,
               cache_creation_tokens INTEGER,
               service_tier          TEXT,
               error                 TEXT,
               final_output          TEXT
             );
           """),
         :ok <-
           Sqlite3.execute(
             db,
             "CREATE INDEX IF NOT EXISTS _worker_log_started_at ON _worker_log(started_at)"
           ),
         :ok <-
           Sqlite3.execute(
             db,
             "CREATE INDEX IF NOT EXISTS _worker_log_worker_name ON _worker_log(worker_name)"
           ) do
      :ok
    end
  end

  defp applied_versions(db) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT version FROM _sark_migrations ORDER BY version")
    rows = fetch_all(db, stmt, [])
    :ok = Sqlite3.release(db, stmt)
    rows |> Enum.map(fn [v] -> v end) |> MapSet.new()
  end

  defp fetch_all(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> fetch_all(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp validate_applied_is_prefix!(plugin_name, applied, file_versions) do
    applied_list = applied |> MapSet.to_list() |> Enum.sort()

    case applied_list do
      [] ->
        :ok

      _ ->
        max_applied = List.last(applied_list)
        expected_prefix = Enum.take(file_versions, max_applied)

        if applied_list != expected_prefix do
          raise "plugin #{plugin_name}: applied migrations #{inspect(applied_list)} are not " <>
                  "a prefix of file migrations #{inspect(file_versions)} — schema drift, refusing to boot"
        end

        missing_files = expected_prefix -- file_versions

        if missing_files != [] do
          raise "plugin #{plugin_name}: applied migrations #{inspect(missing_files)} " <>
                  "have no corresponding file (deleted?), refusing to boot"
        end
    end
  end

  defp apply_one!(db, plugin_name, %{version: ver, path: path, sql: sql}) do
    Logger.info("plugin #{plugin_name} — applying migration #{ver} (#{Path.basename(path)})")

    case run_in_txn(db, sql) do
      :ok ->
        ts = DateTime.utc_now() |> DateTime.to_iso8601()

        case Sqlite3.execute(
               db,
               "INSERT INTO _sark_migrations (version, applied_at) VALUES (#{ver}, '#{ts}')"
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            raise "plugin #{plugin_name}: failed to record migration #{ver}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "plugin #{plugin_name}: migration #{ver} (#{Path.basename(path)}) failed: " <>
                inspect(reason)
    end
  end

  defp run_in_txn(db, sql) do
    with :ok <- Sqlite3.execute(db, "BEGIN"),
         :ok <- Sqlite3.execute(db, sql) do
      Sqlite3.execute(db, "COMMIT")
    else
      {:error, _} = err ->
        _ = Sqlite3.execute(db, "ROLLBACK")
        err
    end
  end
end

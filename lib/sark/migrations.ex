defmodule Sark.Migrations do
  @moduledoc """
  Shared forward-only SQL migration runner.

  Two callers planned: plugin migrations (live in `<plugin>/migrations/`,
  tracker in plugin DB) and sark-internal migrations (live in
  `sark/priv/internal_migrations/`, tracker in sark DB — landing later).
  This module owns the apply loop; callers supply DB path, migration
  list, tracker-table name, and a source label used in log + error
  messages.
  """

  require Logger

  alias Exqlite.Sqlite3

  @type migration :: %{
          version: pos_integer,
          name: String.t(),
          path: Path.t(),
          sql: String.t()
        }

  @doc """
  Apply pending migrations against the DB at `db_path`. Opens the DB,
  sets WAL + foreign_keys, ensures the tracker table exists, validates
  the applied set is a prefix of the file set, then applies any
  unapplied migrations in order. Idempotent.

  Required opts:

    * `:source_label` — string used in log + error messages
      (e.g. `"plugin myplugin"` or `"sark internal"`).
    * `:db_path` — path to the SQLite file.
    * `:migrations` — list of `t:migration/0` (already validated by
      `Sark.Migrations.Discovery.discover!/1`).
    * `:tracker_table` — table name for the version ledger
      (e.g. `"_sark_migrations"`).
  """
  @spec apply!(keyword) :: :ok
  def apply!(opts) do
    source_label = Keyword.fetch!(opts, :source_label)
    db_path = Keyword.fetch!(opts, :db_path)
    migrations = Keyword.fetch!(opts, :migrations)
    tracker_table = Keyword.fetch!(opts, :tracker_table)

    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys = ON")
      :ok = ensure_tracker(db, tracker_table)

      applied = applied_versions(db, tracker_table)
      file_versions = Enum.map(migrations, & &1.version)

      validate_applied_is_prefix!(source_label, applied, file_versions)

      pending = Enum.reject(migrations, fn m -> MapSet.member?(applied, m.version) end)

      Enum.each(pending, fn m -> apply_one!(db, source_label, m, tracker_table) end)

      :ok
    after
      Sqlite3.close(db)
    end
  end

  # `name` left nullable so existing prod trackers (which predate this
  # column) survive an `ALTER TABLE ADD COLUMN name TEXT` without a
  # default. New rows always populate it; manual backfill rescues
  # legacy rows.
  defp ensure_tracker(db, table) do
    Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS #{table} (
        version    INTEGER PRIMARY KEY,
        name       TEXT,
        applied_at TEXT NOT NULL
      );
    """)
  end

  defp applied_versions(db, table) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT version FROM #{table} ORDER BY version")
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

  defp validate_applied_is_prefix!(source_label, applied, file_versions) do
    applied_list = applied |> MapSet.to_list() |> Enum.sort()

    case applied_list do
      [] ->
        :ok

      _ ->
        max_applied = List.last(applied_list)
        expected_prefix = Enum.take(file_versions, max_applied)

        if applied_list != expected_prefix do
          raise "#{source_label}: applied migrations #{inspect(applied_list)} are not " <>
                  "a prefix of file migrations #{inspect(file_versions)} — schema drift, refusing to boot"
        end

        missing_files = expected_prefix -- file_versions

        if missing_files != [] do
          raise "#{source_label}: applied migrations #{inspect(missing_files)} " <>
                  "have no corresponding file (deleted?), refusing to boot"
        end
    end
  end

  defp apply_one!(
         db,
         source_label,
         %{version: ver, name: name, path: path, sql: sql},
         tracker_table
       ) do
    Logger.info("#{source_label} — applying migration #{ver} (#{Path.basename(path)})")

    case run_in_txn(db, sql) do
      :ok ->
        ts = DateTime.utc_now() |> DateTime.to_iso8601()
        escaped_name = String.replace(name, "'", "''")

        case Sqlite3.execute(
               db,
               "INSERT INTO #{tracker_table} (version, name, applied_at) " <>
                 "VALUES (#{ver}, '#{escaped_name}', '#{ts}')"
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            raise "#{source_label}: failed to record migration #{ver}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "#{source_label}: migration #{ver} (#{Path.basename(path)}) failed: " <>
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

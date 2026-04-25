defmodule Sark.Plugin.DB do
  @moduledoc """
  Per-plugin SQLite access. Two DBConnection pools per plugin:

    * **writer** — `pool_size: 1`. Serialises writes; needed because
      SQLite's WAL allows concurrent reads but only one writer.
    * **reader** — `pool_size: 4`. Each conn is opened with
      `PRAGMA query_only = ON` so a buggy SELECT path can't accidentally
      mutate the database.

  Both pools point at the same `.db` file. Pool process names are
  derived from the plugin name so call sites can address them without
  passing pids around.
  """

  alias Exqlite.Result

  @writer_pool_size 1
  @reader_pool_size 4

  @type plugin_name :: String.t()
  @type role :: :read | :write

  @spec writer_name(plugin_name) :: atom
  def writer_name(name), do: :"sark_plugin_#{name}_writer"

  @spec reader_name(plugin_name) :: atom
  def reader_name(name), do: :"sark_plugin_#{name}_reader"

  @doc """
  Child specs for the writer + reader pools. Returned in the order they
  should be started (writer first; if anything ever races on first
  connect, the writer wins).
  """
  @spec pool_children(plugin_name, Path.t()) :: [Supervisor.child_spec()]
  def pool_children(name, db_path) do
    base = [
      database: db_path,
      journal_mode: :wal,
      busy_timeout: 5_000,
      cache_size: -64_000
    ]

    writer_opts =
      base ++
        [
          name: writer_name(name),
          pool_size: @writer_pool_size
        ]

    reader_opts =
      base ++
        [
          name: reader_name(name),
          pool_size: @reader_pool_size,
          custom_pragmas: [{:query_only, true}]
        ]

    [
      Supervisor.child_spec({Exqlite, writer_opts}, id: {:writer, name}),
      Supervisor.child_spec({Exqlite, reader_opts}, id: {:reader, name})
    ]
  end

  @doc """
  Run a SELECT against the read pool. Returns rows as a list of maps
  keyed by column name.
  """
  @spec read(plugin_name, iodata, [term]) :: {:ok, [map]} | {:error, term}
  def read(name, sql, params \\ []) do
    case Exqlite.query(reader_name(name), sql, params) do
      {:ok, %Result{} = r} -> {:ok, rows_to_maps(r)}
      {:error, _} = e -> e
    end
  end

  @doc "Like `read/3` but raises on error."
  @spec read!(plugin_name, iodata, [term]) :: [map]
  def read!(name, sql, params \\ []) do
    case read(name, sql, params) do
      {:ok, rows} -> rows
      {:error, e} -> raise e
    end
  end

  @doc """
  Run a write (INSERT/UPDATE/DELETE/DDL) against the write pool. Returns
  the raw `Exqlite.Result` so callers can read `num_rows` or `rows` (for
  RETURNING clauses).
  """
  @spec write(plugin_name, iodata, [term]) :: {:ok, Result.t()} | {:error, term}
  def write(name, sql, params \\ []) do
    Exqlite.query(writer_name(name), sql, params)
  end

  @doc "Like `write/3` but raises on error."
  @spec write!(plugin_name, iodata, [term]) :: Result.t()
  def write!(name, sql, params \\ []) do
    case write(name, sql, params) do
      {:ok, r} -> r
      {:error, e} -> raise e
    end
  end

  @doc """
  Wrap a function in a transaction on the write pool. The function
  receives the checked-out connection and should use `Exqlite.query/4`
  (or `DBConnection.execute/3`) against it.
  """
  @spec txn(plugin_name, (DBConnection.t() -> any), keyword) ::
          {:ok, any} | {:error, term}
  def txn(name, fun, opts \\ []) do
    DBConnection.transaction(writer_name(name), fun, opts)
  end

  defp rows_to_maps(%Result{rows: nil}), do: []

  defp rows_to_maps(%Result{rows: rows, columns: cols}) when is_list(rows) and is_list(cols) do
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end
end

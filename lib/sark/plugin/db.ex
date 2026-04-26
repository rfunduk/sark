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
  Run a SELECT against the read pool. Returns the column list (in
  SELECT order) alongside rows as a list of maps keyed by column name.
  Callers that render output need the column list to preserve the
  agent-supplied SELECT order; map iteration alone won't.
  """
  @spec read(plugin_name, iodata, [term]) :: {:ok, [String.t()], [map]} | {:error, term}
  def read(name, sql, params \\ []) do
    case Exqlite.query(reader_name(name), sql, params) do
      {:ok, %Result{} = r} -> {:ok, columns(r), rows_to_maps(r)}
      {:error, _} = e -> e
    end
  end

  @doc "Like `read/3` but raises on error."
  @spec read!(plugin_name, iodata, [term]) :: {[String.t()], [map]}
  def read!(name, sql, params \\ []) do
    case read(name, sql, params) do
      {:ok, cols, rows} -> {cols, rows}
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

  @doc """
  Column names (in SELECT order) from an Exqlite result.
  """
  @spec columns(Result.t()) :: [String.t()]
  def columns(%Result{columns: cols}) when is_list(cols), do: cols
  def columns(%Result{}), do: []

  @doc """
  Rows from an Exqlite result as a list of maps keyed by column name.
  Order is lost on the map; pair with `columns/1` if you need it.

  String values that look like JSON (start with `[` or `{`) are decoded
  with `Jason.decode/1`; on parse error the original string passes
  through. Lets `json_object` / `json_group_array` composites in SQL
  surface as nested data without the caller needing to decode.
  """
  @spec rows_to_maps(Result.t()) :: [map]
  def rows_to_maps(%Result{rows: nil}), do: []

  def rows_to_maps(%Result{rows: rows, columns: cols}) when is_list(rows) and is_list(cols) do
    Enum.map(rows, fn row ->
      cols
      |> Enum.zip(row)
      |> Enum.map(fn {k, v} -> {k, maybe_decode_json(v)} end)
      |> Map.new()
    end)
  end

  defp maybe_decode_json(<<"[", _::binary>> = v), do: try_decode(v)
  defp maybe_decode_json(<<"{", _::binary>> = v), do: try_decode(v)
  defp maybe_decode_json(v), do: v

  defp try_decode(v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      {:error, _} -> v
    end
  end
end

defmodule Sark.Plugin.DB do
  @moduledoc """
  Per-plugin SQLite access. Each plugin gets two DBs, each with two
  pools:

    * `:data` — plugin-authored tables. The plugin migration track
      applies here. This is what plugin tools read and write.
    * `:sark` — framework-managed tables (versioned schema track,
      observability log, future internal state). Sark owns the schema;
      plugin authors never write here directly.

  Per DB:

    * **writer** — `pool_size: 1`. Serialises writes; SQLite's WAL
      allows concurrent reads but only one writer.
    * **reader** — `pool_size: 4`. Each conn opened with
      `PRAGMA query_only = ON` so a buggy SELECT can't mutate.

  Pool process names are derived from the plugin name + DB kind so
  call sites can address them without passing pids around. The
  one-arg `writer_name/1` / `reader_name/1` default to the `:data`
  DB for backwards compatibility — existing call sites keep working.
  """

  alias Exqlite.Result

  @writer_pool_size 1
  @reader_pool_size 4
  @cache_size -16_000
  @mmap_size 268_435_456

  @type plugin_name :: String.t()
  @type role :: :read | :write
  @type db_kind :: :data | :sark

  @spec writer_name(plugin_name) :: atom
  def writer_name(name), do: writer_name(name, :data)

  @spec writer_name(plugin_name, db_kind) :: atom
  def writer_name(name, :data), do: :"sark_plugin_#{name}_writer"
  def writer_name(name, :sark), do: :"sark_plugin_#{name}_sark_writer"

  @spec reader_name(plugin_name) :: atom
  def reader_name(name), do: reader_name(name, :data)

  @spec reader_name(plugin_name, db_kind) :: atom
  def reader_name(name, :data), do: :"sark_plugin_#{name}_reader"
  def reader_name(name, :sark), do: :"sark_plugin_#{name}_sark_reader"

  @doc """
  Sibling sark DB path derived from the plugin DB path
  (`<dir>/<name>.db` → `<dir>/<name>.sark.db`).
  """
  @spec sark_db_path(Path.t()) :: Path.t()
  def sark_db_path(data_db_path) do
    dir = Path.dirname(data_db_path)
    base = Path.basename(data_db_path, ".db")
    Path.join(dir, "#{base}.sark.db")
  end

  @doc """
  Child specs for both DBs' writer + reader pools. Returned in start
  order: sark writer + reader first, then data writer + reader. Sark
  DB starts first so its tables exist before the data pools come up
  and start serving queries that may reference framework state.

  Opts:

    * `:data_load_extensions` — list of paths to SQLite loadable
      extensions to load on every data-pool conn (writer + reader).
      Used to wire `sqlite-vec` (vec0) into plugins that declare
      `embed:`. Sark-pool conns never load extensions — they hold
      framework state only.
    * `:readers` — reader pool size. Default `#{@reader_pool_size}`.
    * `:cache_size` — SQLite `cache_size` PRAGMA (negative = KiB,
      positive = pages). Default `#{@cache_size}` (~16MB per conn).
    * `:mmap_size` — SQLite `mmap_size` PRAGMA in bytes. Zero-copy
      shared OS page cache. Default `#{@mmap_size}` (256MB).
  """
  @spec pool_children(plugin_name, Path.t(), keyword) :: [Supervisor.child_spec()]
  def pool_children(name, data_db_path, opts \\ []) do
    sark_path = sark_db_path(data_db_path)
    data_extensions = Keyword.get(opts, :data_load_extensions, [])

    pool_pair(name, :sark, sark_path, [], opts) ++
      pool_pair(name, :data, data_db_path, data_extensions, opts)
  end

  defp pool_pair(name, kind, db_path, extensions, opts) do
    readers = Keyword.get(opts, :readers, @reader_pool_size)
    cache_size = Keyword.get(opts, :cache_size, @cache_size)
    mmap_size = Keyword.get(opts, :mmap_size, @mmap_size)

    base = [
      database: db_path,
      journal_mode: :wal,
      busy_timeout: 5_000,
      cache_size: cache_size,
      custom_pragmas: [{:mmap_size, mmap_size}]
    ]

    base =
      if extensions == [], do: base, else: base ++ [load_extensions: extensions]

    writer_opts =
      base ++
        [
          name: writer_name(name, kind),
          pool_size: @writer_pool_size
        ]

    reader_opts =
      Keyword.merge(base,
        name: reader_name(name, kind),
        pool_size: readers,
        custom_pragmas: [{:mmap_size, mmap_size}, {:query_only, true}]
      )

    [
      Supervisor.child_spec({Exqlite, writer_opts}, id: {:writer, name, kind}),
      Supervisor.child_spec({Exqlite, reader_opts}, id: {:reader, name, kind})
    ]
  end

  @doc """
  Run a SELECT against the read pool. Returns the column list (in
  SELECT order) alongside rows as a list of maps keyed by column name.
  Callers that render output need the column list to preserve the
  agent-supplied SELECT order; map iteration alone won't.

  Pass `conn:` in `opts` to run on a specific DBConnection instead of
  the read pool — used by transactional pipelines that need reads to
  see uncommitted writes against the held writer connection.
  """
  @spec read(plugin_name, iodata, [term], keyword) ::
          {:ok, [String.t()], [map]} | {:error, term}
  def read(name, sql, params \\ [], opts \\ []) do
    target = Keyword.get(opts, :conn) || reader_name(name)

    case Exqlite.query(target, sql, params) do
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

  # ── sark DB variants ───────────────────────────────────────────────────────
  #
  # Mirror of `read/3`, `write/3`, `txn/2` against the sark-managed DB.
  # Used by framework code (observability, log writers, future internal
  # tools); plugin tools should never call these directly.

  @doc "Like `read/4` but against the sark DB."
  @spec sark_read(plugin_name, iodata, [term], keyword) ::
          {:ok, [String.t()], [map]} | {:error, term}
  def sark_read(name, sql, params \\ [], opts \\ []) do
    target = Keyword.get(opts, :conn) || reader_name(name, :sark)

    case Exqlite.query(target, sql, params) do
      {:ok, %Result{} = r} -> {:ok, columns(r), rows_to_maps(r)}
      {:error, _} = e -> e
    end
  end

  @doc "Like `write/3` but against the sark DB."
  @spec sark_write(plugin_name, iodata, [term]) :: {:ok, Result.t()} | {:error, term}
  def sark_write(name, sql, params \\ []) do
    Exqlite.query(writer_name(name, :sark), sql, params)
  end

  @doc "Like `txn/3` but against the sark DB."
  @spec sark_txn(plugin_name, (DBConnection.t() -> any), keyword) ::
          {:ok, any} | {:error, term}
  def sark_txn(name, fun, opts \\ []) do
    DBConnection.transaction(writer_name(name, :sark), fun, opts)
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

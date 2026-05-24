defmodule Sark.Plugin.EmbedMigrator do
  @moduledoc """
  Idempotent DDL for the *dynamic* (per-table) embed surface on a
  plugin's data DB. Runs after the plugin's migration tracks have
  applied, via a one-shot raw conn (no pool yet).

  Static sark-managed tables (currently just `_embed_queue`) live in
  `priv/plugin_migrations/` and are applied separately as a normal
  migration track. This module owns only what depends on the plugin's
  declared `embed:` config — those tables are derived from plugin
  data and can be dropped + rebuilt without losing source-of-truth.

  Per call, this module:

    * Loads the `vec0` SQLite extension (then disables further
      load_extension calls on the conn)
    * For every entry in `Spec.embed`:
        - Creates `_embeddings_<table>` (vec0 virtual table, fixed
          `dim` from `config.embedder.dim`)
        - Creates `_embeddings_<table>_meta` (row_pk, field, chunk_*,
          hashes, embedded_at)
        - Drops + recreates the AFTER INSERT/UPDATE/DELETE triggers
          on `<table>` (keeps them in sync with config changes —
          e.g. pk rename)
    * Drops any orphans: `_embeddings_*` + `_meta` + triggers +
      queue rows for tables that used to be in `embed:` but aren't
      anymore. Triggers on a dropped plugin table auto-vanish via
      SQLite; this handles the "still-have-the-table, just removed
      the embed entry" case.

  When `Spec.embed` is empty, this module is a no-op and is never
  called.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias Sark.Embedder.Config, as: EmbedConfig
  alias Sark.Plugin.Embed

  @doc """
  Apply embed DDL to the plugin data DB. Caller must guarantee that
  `embed` is non-empty and that `embedder` is configured.

    * `plugin_name` — for log labels
    * `db_path` — plugin data DB file
    * `embed` — `Spec.embed` (table → %Embed{}) from the YAML loader
    * `embedder` — `%Sark.Embedder.Config{}` (provides `dim`)
    * `vec0_path` — path to the loadable `vec0` extension
      (`SqliteVec.path/0`)
  """
  @spec apply!(String.t(), Path.t(), %{String.t() => Embed.t()}, EmbedConfig.t() | nil, Path.t()) ::
          :ok
  def apply!(plugin_name, _db_path, embed, nil, _vec0_path) when map_size(embed) > 0 do
    raise "plugin #{plugin_name}: declares embed: but embedder: is not configured in config.yml"
  end

  def apply!(plugin_name, db_path, embed, %EmbedConfig{dim: dim}, vec0_path)
      when map_size(embed) > 0 do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = load_vec0!(db, plugin_name, vec0_path)
      :ok = cleanup_orphans!(db, plugin_name, embed)

      Enum.each(embed, fn {table, spec} ->
        :ok = create_embeddings!(db, plugin_name, table, dim)
        :ok = create_meta!(db, plugin_name, table)
        :ok = install_triggers!(db, plugin_name, spec)
      end)

      Logger.info("embed migrate (#{plugin_name}) — #{map_size(embed)} table(s) ready")

      :ok
    after
      Sqlite3.close(db)
    end
  end

  # ── extension load ────────────────────────────────────────────────────

  defp load_vec0!(db, plugin_name, path) do
    case Sqlite3.enable_load_extension(db, true) do
      :ok ->
        case Sqlite3.execute(db, "SELECT load_extension('#{escape(path)}')") do
          :ok ->
            # Lock the extension surface back down so subsequent writes
            # can't pull arbitrary .so files via SQL.
            :ok = Sqlite3.enable_load_extension(db, false)
            :ok

          {:error, reason} ->
            raise "embed migrate (#{plugin_name}): failed to load vec0 from `#{path}`: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "embed migrate (#{plugin_name}): enable_load_extension failed: #{inspect(reason)}"
    end
  end

  # ── orphan cleanup ───────────────────────────────────────────────────

  # Drop derived state for tables that used to be in `embed:` but
  # aren't anymore. Idempotent: a fresh plugin has no `_embeddings_*`
  # tables and no work to do here.
  defp cleanup_orphans!(db, plugin_name, embed) do
    declared = MapSet.new(Map.keys(embed))
    existing = list_embedded_tables!(db, plugin_name)

    orphans =
      existing
      |> MapSet.new()
      |> MapSet.difference(declared)
      |> MapSet.to_list()

    Enum.each(orphans, fn table ->
      Logger.info("embed migrate (#{plugin_name}) — dropping orphan embed surface for `#{table}`")

      :ok = drop_orphan!(db, plugin_name, table)
    end)

    :ok
  end

  # Only the *virtual tables* created via `USING vec0` are real
  # _embeddings_<X> entries. vec0 also creates shadow tables
  # (`_embeddings_X_chunks`, `_embeddings_X_rowids`,
  # `_embeddings_X_vector_chunks00`, ...) that share the prefix but
  # auto-cascade when the parent virtual table is dropped — we must
  # not enumerate them as orphans.
  defp list_embedded_tables!(db, plugin_name) do
    sql = """
    SELECT name FROM sqlite_master
    WHERE type = 'table'
      AND name LIKE '\\_embeddings\\_%' ESCAPE '\\'
      AND name NOT LIKE '%\\_meta' ESCAPE '\\'
      AND sql LIKE 'CREATE VIRTUAL TABLE%USING vec0%'
    """

    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        rows = fetch_all(db, stmt, [])
        :ok = Sqlite3.release(db, stmt)
        Enum.map(rows, fn [name] -> String.replace_prefix(name, "_embeddings_", "") end)

      {:error, reason} ->
        raise "embed migrate (#{plugin_name}): list embed tables failed: #{inspect(reason)}"
    end
  end

  defp fetch_all(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> fetch_all(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp drop_orphan!(db, plugin_name, table) do
    statements = [
      "DROP TRIGGER IF EXISTS _embed_#{table}_ai",
      "DROP TRIGGER IF EXISTS _embed_#{table}_au",
      "DROP TRIGGER IF EXISTS _embed_#{table}_ad",
      "DROP TABLE IF EXISTS _embeddings_#{table}_meta",
      "DROP TABLE IF EXISTS _embeddings_#{table}",
      "DELETE FROM _embed_queue WHERE table_name = '#{table}'"
    ]

    Enum.each(statements, fn sql ->
      case Sqlite3.execute(db, sql) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "embed migrate (#{plugin_name}): orphan drop `#{sql}` failed: " <>
                  inspect(reason)
      end
    end)

    :ok
  end

  # ── per-table tables ─────────────────────────────────────────────────

  defp create_embeddings!(db, plugin_name, table, dim) do
    sql =
      "CREATE VIRTUAL TABLE IF NOT EXISTS _embeddings_#{table} " <>
        "USING vec0(embedding float[#{dim}])"

    case Sqlite3.execute(db, sql) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "embed migrate (#{plugin_name}): _embeddings_#{table} create failed: #{inspect(reason)}"
    end
  end

  defp create_meta!(db, plugin_name, table) do
    sql = """
    CREATE TABLE IF NOT EXISTS _embeddings_#{table}_meta (
      id            INTEGER PRIMARY KEY,
      row_pk        TEXT    NOT NULL,
      field         TEXT    NOT NULL,
      chunk_index   INTEGER NOT NULL DEFAULT 0,
      chunk_text    TEXT    NOT NULL,
      content_hash  TEXT    NOT NULL,
      config_hash   TEXT    NOT NULL,
      embedded_at   TEXT    NOT NULL
    )
    """

    case Sqlite3.execute(db, sql) do
      :ok ->
        :ok =
          Sqlite3.execute(
            db,
            "CREATE INDEX IF NOT EXISTS _embeddings_#{table}_meta_row " <>
              "ON _embeddings_#{table}_meta(row_pk)"
          )

        :ok

      {:error, reason} ->
        raise "embed migrate (#{plugin_name}): _embeddings_#{table}_meta create failed: #{inspect(reason)}"
    end
  end

  # ── triggers ─────────────────────────────────────────────────────────

  defp install_triggers!(db, plugin_name, %Embed{table: table, pk: pk}) do
    Enum.each(
      [
        {"ai", "AFTER INSERT", "NEW.#{pk}", "INSERT"},
        {"au", "AFTER UPDATE", "NEW.#{pk}", "UPDATE"},
        {"ad", "AFTER DELETE", "OLD.#{pk}", "DELETE"}
      ],
      fn {suffix, when_clause, pk_ref, op} ->
        name = "_embed_#{table}_#{suffix}"
        drop_sql = "DROP TRIGGER IF EXISTS #{name}"

        create_sql = """
        CREATE TRIGGER #{name}
        #{when_clause} ON #{table}
        BEGIN
          INSERT INTO _embed_queue (table_name, row_pk, op, enqueued_at)
          VALUES ('#{table}', #{pk_ref}, '#{op}', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        END
        """

        case Sqlite3.execute(db, drop_sql) do
          :ok -> :ok
          {:error, reason} -> raise drop_err(plugin_name, name, reason)
        end

        case Sqlite3.execute(db, create_sql) do
          :ok -> :ok
          {:error, reason} -> raise create_err(plugin_name, name, reason)
        end
      end
    )

    :ok
  end

  defp drop_err(plugin, name, reason),
    do: "embed migrate (#{plugin}): drop trigger #{name} failed: #{inspect(reason)}"

  defp create_err(plugin, name, reason),
    do: "embed migrate (#{plugin}): create trigger #{name} failed: #{inspect(reason)}"

  # SQLite identifiers + paths in this module are all under sark's control
  # (paths come from SqliteVec.path/0; identifiers are pre-validated by
  # Embed.parse! against a strict regex). Escape single quotes anyway as
  # belt-and-suspenders for the load_extension SQL literal.
  defp escape(s), do: String.replace(s, "'", "''")
end

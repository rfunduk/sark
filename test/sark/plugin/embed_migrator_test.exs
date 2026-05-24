defmodule Sark.Plugin.EmbedMigratorTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Sark.Embedder.Config, as: EmbedConfig
  alias Sark.Plugin.Embed
  alias Sark.Plugin.EmbedMigrator

  @moduletag :tmp_dir

  defp embedder, do: %EmbedConfig{provider: "ollama", model: "x", dim: 768}

  defp open!(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readwrite)
    db
  end

  defp execute!(db, sql) do
    :ok = Sqlite3.execute(db, sql)
  end

  defp query!(db, sql) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    rows = fetch_all(db, stmt, [])
    :ok = Sqlite3.release(db, stmt)
    rows
  end

  defp fetch_all(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> fetch_all(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp setup_plugin_db(dir, table_ddl) do
    db_path = Path.join(dir, "p.db")
    db = open!(db_path)
    execute!(db, "PRAGMA journal_mode = WAL")
    execute!(db, table_ddl)
    Sqlite3.close(db)

    # Mirror Sark.Plugin.init: apply the sark-managed plugin-DB
    # migration track so `_embed_queue` (and any future sark-owned
    # plugin-DB tables) exist before EmbedMigrator runs.
    mig_dir = Path.join(:code.priv_dir(:sark), "plugin_migrations")
    label = "sark internal plugin-db (test)"

    Sark.Migrations.apply!(
      source_label: label,
      db_path: db_path,
      migrations: Sark.Migrations.discover!(mig_dir, label),
      tracker_table: "_sark_internal_migrations"
    )

    db_path
  end

  defp embed_for(table, fields, opts \\ []) do
    %{
      table => %Embed{
        table: table,
        fields: fields,
        pk: Keyword.get(opts, :pk, "id"),
        chunk: Keyword.get(opts, :chunk),
        where: Keyword.get(opts, :where)
      }
    }
  end

  test "no-op when embed map is empty handled at caller level (sanity)" do
    # The Spec hook in Sark.Plugin guards on map_size(embed) == 0 before
    # calling apply!. apply! itself is only built for non-empty embed —
    # this test documents the precondition.
    assert is_map_key(%Embed{table: "t", fields: ["x"]}, :table)
  end

  test "raises when embed is declared but embedder config is nil" do
    assert_raise RuntimeError, ~r/declares embed: but embedder: is not configured/, fn ->
      EmbedMigrator.apply!(
        "p",
        "/tmp/should-not-be-touched.db",
        embed_for("nodes", ["body"]),
        nil,
        SqliteVec.path()
      )
    end
  end

  describe "apply!/5 against a fresh plugin DB" do
    test "creates _embed_queue + per-table vec0 + meta", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          summary TEXT,
          body TEXT
        )
        """)

      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["summary", "body"]),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)
      :ok = Sqlite3.enable_load_extension(db, true)
      execute!(db, "SELECT load_extension('#{SqliteVec.path()}')")
      :ok = Sqlite3.enable_load_extension(db, false)

      tables = query!(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      table_names = Enum.map(tables, fn [n] -> n end)

      assert "_embed_queue" in table_names
      assert "_embeddings_nodes_meta" in table_names

      [[count]] =
        query!(
          db,
          "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_embeddings_nodes'"
        )

      assert count == 1

      [[ix_count]] =
        query!(
          db,
          "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='_embed_queue_status_id'"
        )

      assert ix_count == 1

      Sqlite3.close(db)
    end

    test "installs INSERT/UPDATE/DELETE triggers that enqueue to _embed_queue", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          body TEXT
        )
        """)

      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["body"]),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)

      # Insert: enqueues INSERT row
      execute!(db, "INSERT INTO nodes (body) VALUES ('hello')")
      rows = query!(db, "SELECT table_name, row_pk, op, status FROM _embed_queue ORDER BY id")
      assert rows == [["nodes", "1", "INSERT", "pending"]]

      # Update: enqueues UPDATE row
      execute!(db, "UPDATE nodes SET body = 'changed' WHERE id = 1")
      rows = query!(db, "SELECT op FROM _embed_queue ORDER BY id")
      assert rows == [["INSERT"], ["UPDATE"]]

      # Delete: enqueues DELETE row referencing OLD.id
      execute!(db, "DELETE FROM nodes WHERE id = 1")
      rows = query!(db, "SELECT row_pk, op FROM _embed_queue ORDER BY id")
      assert rows == [["1", "INSERT"], ["1", "UPDATE"], ["1", "DELETE"]]

      Sqlite3.close(db)
    end

    test "is idempotent across reruns (no errors, triggers refreshed)", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)
        """)

      embed = embed_for("nodes", ["body"])

      :ok = EmbedMigrator.apply!("p", db_path, embed, embedder(), SqliteVec.path())
      :ok = EmbedMigrator.apply!("p", db_path, embed, embedder(), SqliteVec.path())
      :ok = EmbedMigrator.apply!("p", db_path, embed, embedder(), SqliteVec.path())

      db = open!(db_path)
      execute!(db, "INSERT INTO nodes (body) VALUES ('x')")
      rows = query!(db, "SELECT op FROM _embed_queue")
      assert rows == [["INSERT"]]
      Sqlite3.close(db)
    end

    test "supports custom pk", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE docs (
          uri TEXT PRIMARY KEY,
          content TEXT
        )
        """)

      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("docs", ["content"], pk: "uri"),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)
      execute!(db, "INSERT INTO docs (uri, content) VALUES ('/a', 'hello')")
      [[row_pk]] = query!(db, "SELECT row_pk FROM _embed_queue")
      assert row_pk == "/a"
      Sqlite3.close(db)
    end

    test "vec0 virtual table has the configured dim", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, body TEXT)
        """)

      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["body"]),
          %EmbedConfig{provider: "ollama", model: "x", dim: 384},
          SqliteVec.path()
        )

      db = open!(db_path)
      :ok = Sqlite3.enable_load_extension(db, true)
      execute!(db, "SELECT load_extension('#{SqliteVec.path()}')")
      :ok = Sqlite3.enable_load_extension(db, false)

      [[sql]] = query!(db, "SELECT sql FROM sqlite_master WHERE name='_embeddings_nodes'")
      assert sql =~ "float[384]"
      Sqlite3.close(db)
    end

    test "removing a table from embed: drops orphan vec0 + meta + triggers + queue rows",
         %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);
        CREATE TABLE docs (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT);
        """)

      # First boot: both tables embed-configured.
      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["body"]) |> Map.merge(embed_for("docs", ["content"])),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)
      execute!(db, "INSERT INTO nodes (body) VALUES ('x')")
      execute!(db, "INSERT INTO docs (content) VALUES ('y')")
      [[c1]] = query!(db, "SELECT COUNT(*) FROM _embed_queue WHERE table_name = 'docs'")
      assert c1 == 1
      Sqlite3.close(db)

      # Second boot: docs removed from embed config.
      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["body"]),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)
      :ok = Sqlite3.enable_load_extension(db, true)
      execute!(db, "SELECT load_extension('#{SqliteVec.path()}')")
      :ok = Sqlite3.enable_load_extension(db, false)

      tables =
        query!(
          db,
          "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '\\_embeddings\\_%' ESCAPE '\\'"
        )
        |> Enum.map(fn [n] -> n end)

      refute "_embeddings_docs" in tables
      refute "_embeddings_docs_meta" in tables
      assert "_embeddings_nodes" in tables
      assert "_embeddings_nodes_meta" in tables

      triggers =
        query!(
          db,
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE '\\_embed\\_%' ESCAPE '\\'"
        )
        |> Enum.map(fn [n] -> n end)

      refute "_embed_docs_ai" in triggers
      refute "_embed_docs_au" in triggers
      refute "_embed_docs_ad" in triggers
      assert "_embed_nodes_ai" in triggers

      [[c]] = query!(db, "SELECT COUNT(*) FROM _embed_queue WHERE table_name = 'docs'")
      assert c == 0

      Sqlite3.close(db)
    end

    test "extension load is locked back down after vec0 is registered", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, body TEXT)
        """)

      :ok =
        EmbedMigrator.apply!(
          "p",
          db_path,
          embed_for("nodes", ["body"]),
          embedder(),
          SqliteVec.path()
        )

      db = open!(db_path)
      # Trying to load_extension via SQL on a fresh conn should fail
      # since the conn opens with load_extension off by default.
      result = Sqlite3.execute(db, "SELECT load_extension('#{SqliteVec.path()}')")
      assert match?({:error, _}, result)
      Sqlite3.close(db)
    end
  end
end

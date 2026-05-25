defmodule Sark.MCP.Handlers.EmbedTest do
  # Embed admin built-ins + auto-generated sark_vec_<X> search tool.
  # External: only the embedder adapter (TestStub).
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Sark.Embedder.Cache
  alias Sark.Embedder.Config, as: EmbedderConfig
  alias Sark.MCP.Internal
  alias Sark.MCP.Registration
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Embed
  alias Sark.Plugin.EmbedDrain
  alias Sark.Plugin.EmbedMigrator
  alias Sark.Plugin.Spec

  @moduletag :tmp_dir

  @stub_provider "stub"
  @stub_model "stub-model"
  @dim 16

  defmodule TestStub do
    @moduledoc false
    @behaviour Sark.Embedder

    @impl true
    def embed(texts, %EmbedderConfig{dim: dim}) do
      {:ok, Enum.map(texts, &deterministic(&1, dim))}
    end

    defp deterministic(text, dim) do
      base = :erlang.phash2(text, 1_000_000)

      for i <- 0..(dim - 1) do
        :erlang.phash2({base, i}, 10_000) / 10_000.0 - 0.5
      end
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:sark, :embedder_adapter_overrides, %{@stub_provider => TestStub})
    Application.put_env(:sark, :embedder_spec_override, embedder())
    Cache.clear()

    SarkRegistry.ensure_table()

    on_exit(fn ->
      Application.delete_env(:sark, :embedder_adapter_overrides)
      Application.delete_env(:sark, :embedder_spec_override)
      Cache.clear()
    end)

    name = "p_#{System.unique_integer([:positive])}"
    {db_path, embed} = build_plugin(dir, name)

    spec = %Spec{
      name: name,
      dir: dir,
      migrations: [],
      tools: [],
      pipelines: [],
      embed: embed,
      allow_sql: false,
      patchable: %{}
    }

    Registration.register_plugin!(spec)

    sup = start_pools!(name, db_path)
    drain = start_drain!(name, embed)

    on_exit(fn ->
      if Process.alive?(drain), do: GenServer.stop(drain)
      if Process.alive?(sup), do: Supervisor.stop(sup)
    end)

    {:ok, plugin: name, spec: spec, embed: embed}
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp embedder, do: %EmbedderConfig{provider: @stub_provider, model: @stub_model, dim: @dim}

  defp build_plugin(dir, name) do
    db_path = Path.join(dir, "#{name}.db")

    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")

    :ok =
      Sqlite3.execute(db, """
        CREATE TABLE nodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          body TEXT
        )
      """)

    Sqlite3.close(db)

    mig_dir = Path.join(:code.priv_dir(:sark), "plugin_migrations")
    label = "sark internal plugin-db (test)"

    Sark.Migrations.apply!(
      source_label: label,
      db_path: db_path,
      migrations: Sark.Migrations.discover!(mig_dir, label),
      tracker_table: "_sark_internal_migrations"
    )

    embed = %{"nodes" => %Embed{table: "nodes", fields: ["body"], pk: "id"}}

    EmbedMigrator.apply!(name, db_path, embed, embedder(), SqliteVec.path())

    {db_path, embed}
  end

  defp start_pools!(plugin, db_path) do
    children =
      DB.pool_children(plugin, db_path, data_load_extensions: [SqliteVec.path()])

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(sup)
    sup
  end

  defp start_drain!(plugin, embed) do
    {:ok, pid} =
      EmbedDrain.start_link(
        plugin: plugin,
        embed: embed,
        embedder: embedder(),
        embedder_impl: TestStub,
        max_attempts: 3,
        backoff_base_ms: 1
      )

    Process.unlink(pid)
    pid
  end

  defp seed_and_drain(plugin, bodies) do
    Enum.each(bodies, fn body ->
      DB.write!(plugin, "INSERT INTO nodes (body) VALUES (?)", [body])
    end)

    {:ok, _} = EmbedDrain.drain_now(plugin)
  end

  defp call_json!(plugin, tool, params) do
    {:ok, json} = Internal.call_tool(plugin, tool, params)
    Jason.decode!(json)
  end

  # ── sark_vec_<X> ─────────────────────────────────────────────────────

  describe "sark_vec_<table> (auto-generated)" do
    test "is registered automatically alongside any plugin tools", %{plugin: p} do
      assert {:ok, %Sark.Plugin.Tool{}} = SarkRegistry.get(p, :sark_vec_nodes)
    end

    test "exact-text query returns the matching row first", %{plugin: p} do
      seed_and_drain(p, ["apple", "banana", "cherry"])

      rows = call_json!(p, "sark_vec_nodes", %{"q" => "apple", "limit" => 3})

      assert length(rows) == 3
      [first | _] = rows
      assert first["body"] == "apple"
      assert first["chunk_preview"] == "apple"
      assert_in_delta first["similarity"], 1.0, 0.0001
    end

    test "limit caps the underlying KNN k", %{plugin: p} do
      seed_and_drain(p, ["apple", "banana", "cherry", "date"])

      rows = call_json!(p, "sark_vec_nodes", %{"q" => "apple", "limit" => 2})
      assert length(rows) <= 2
    end

    test "limit defaults to 10 when omitted", %{plugin: p} do
      seed_and_drain(p, Enum.map(1..15, &"item-#{&1}"))

      rows = call_json!(p, "sark_vec_nodes", %{"q" => "item-1"})
      assert length(rows) <= 10
    end

    test "source row columns surface as result fields", %{plugin: p} do
      seed_and_drain(p, ["apple"])

      [row] = call_json!(p, "sark_vec_nodes", %{"q" => "apple", "limit" => 1})

      # `id` from the nodes table, plus chunk_preview + similarity from sark.
      assert Map.has_key?(row, "id")
      assert Map.has_key?(row, "body")
      assert Map.has_key?(row, "chunk_preview")
      assert Map.has_key?(row, "similarity")
    end
  end

  # ── sark_embed_status ────────────────────────────────────────────────

  describe "sark_embed_status" do
    test "reports queue counts and embedder spec", %{plugin: p} do
      # Seed but don't drain — leave rows pending.
      Enum.each(["a", "b", "c"], fn body ->
        DB.write!(p, "INSERT INTO nodes (body) VALUES (?)", [body])
      end)

      doc = call_json!(p, "sark_embed_status", %{})

      assert doc["plugin"] == p
      assert doc["queue"]["by_status"]["pending"] == 3

      # by_table breakdown
      by_table = doc["queue"]["by_table"]
      assert Enum.any?(by_table, &(&1["table_name"] == "nodes"))

      assert doc["last_enqueued_at"] != nil
    end

    test "after draining, pending count drops to 0", %{plugin: p} do
      seed_and_drain(p, ["a", "b"])

      doc = call_json!(p, "sark_embed_status", %{})
      assert Map.get(doc["queue"]["by_status"], "pending", 0) == 0
    end
  end

  # ── sark_embed_reindex ───────────────────────────────────────────────

  describe "sark_embed_reindex" do
    test "drops + recreates vec0/meta so schema drift is healed", %{plugin: p} do
      seed_and_drain(p, ["a"])

      # Simulate prior-format vec0 table by inspecting the live CREATE
      # statement after seed.
      {:ok, _, [%{"sql" => sql_before}]} =
        DB.read(
          p,
          "SELECT sql FROM sqlite_master WHERE name = '_embeddings_nodes'",
          []
        )

      assert sql_before =~ "distance_metric=cosine"

      # Reindex — vec0 should be recreated, statement still cosine.
      _ = call_json!(p, "sark_embed_reindex", %{"table" => "nodes"})

      {:ok, _, [%{"sql" => sql_after}]} =
        DB.read(
          p,
          "SELECT sql FROM sqlite_master WHERE name = '_embeddings_nodes'",
          []
        )

      assert sql_after =~ "distance_metric=cosine"
      # Meta got the same treatment.
      {:ok, _, [%{"sql" => meta_sql}]} =
        DB.read(
          p,
          "SELECT sql FROM sqlite_master WHERE name = '_embeddings_nodes_meta'",
          []
        )

      assert meta_sql =~ "row_pk"
    end

    test "wipes embeddings + enqueues every matching source row", %{plugin: p} do
      seed_and_drain(p, ["a", "b", "c"])

      # Sanity: vectors landed.
      assert vec_count(p, "nodes") == 3
      assert meta_count(p, "nodes") == 3

      doc = call_json!(p, "sark_embed_reindex", %{"table" => "nodes"})

      assert doc["table"] == "nodes"
      assert doc["enqueued"] == 3

      # Embeddings + meta wiped pre-drain.
      assert vec_count(p, "nodes") == 0
      assert meta_count(p, "nodes") == 0

      # Re-drain rebuilds.
      {:ok, _} = EmbedDrain.drain_now(p)
      assert vec_count(p, "nodes") == 3
    end

    test "respects where: predicate when enqueueing", %{tmp_dir: dir} do
      name = "p_w_#{System.unique_integer([:positive])}"

      # Hand-rolled setup with a `where:` predicate.
      db_path = Path.join(dir, "#{name}.db")
      {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")

      :ok =
        Sqlite3.execute(db, """
          CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            body TEXT,
            status TEXT NOT NULL DEFAULT 'open'
          )
        """)

      Sqlite3.close(db)

      mig_dir = Path.join(:code.priv_dir(:sark), "plugin_migrations")

      Sark.Migrations.apply!(
        source_label: "test",
        db_path: db_path,
        migrations: Sark.Migrations.discover!(mig_dir, "test"),
        tracker_table: "_sark_internal_migrations"
      )

      embed = %{
        "items" => %Embed{
          table: "items",
          fields: ["body"],
          pk: "id",
          where: "status != 'archived'"
        }
      }

      EmbedMigrator.apply!(name, db_path, embed, embedder(), SqliteVec.path())

      spec = %Spec{
        name: name,
        dir: dir,
        migrations: [],
        tools: [],
        pipelines: [],
        embed: embed,
        allow_sql: false,
        patchable: %{}
      }

      Registration.register_plugin!(spec)

      sup = start_pools!(name, db_path)
      drain = start_drain!(name, embed)

      on_exit(fn ->
        if Process.alive?(drain), do: GenServer.stop(drain)
        if Process.alive?(sup), do: Supervisor.stop(sup)
      end)

      {:ok, _} =
        DB.write(name, "INSERT INTO items (body, status) VALUES ('keep', 'open')", [])

      {:ok, _} =
        DB.write(name, "INSERT INTO items (body, status) VALUES ('skip', 'archived')", [])

      {:ok, _} = EmbedDrain.drain_now(name)

      doc = call_json!(name, "sark_embed_reindex", %{"table" => "items"})
      # Only the non-archived row should be enqueued.
      assert doc["enqueued"] == 1
    end

    test "rejects an unknown table", %{plugin: p} do
      assert {:error, msg} = Internal.call_tool(p, "sark_embed_reindex", %{"table" => "ghost"})
      assert msg =~ "validation:"
      assert msg =~ "ghost"
    end

    test "rejects missing table param", %{plugin: p} do
      assert {:error, msg} = Internal.call_tool(p, "sark_embed_reindex", %{})
      assert msg =~ "validation:"
      assert msg =~ "table"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp vec_count(plugin, table) do
    {:ok, _, [%{"count" => c}]} =
      DB.read(plugin, "SELECT COUNT(*) AS count FROM _embeddings_#{table}", [])

    c
  end

  defp meta_count(plugin, table) do
    {:ok, _, [%{"count" => c}]} =
      DB.read(plugin, "SELECT COUNT(*) AS count FROM _embeddings_#{table}_meta", [])

    c
  end
end

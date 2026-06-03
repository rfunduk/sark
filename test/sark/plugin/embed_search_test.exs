defmodule Sark.Plugin.EmbedSearchTest do
  # Integration: end-to-end query against a real plugin DB seeded by
  # the real EmbedDrain, dispatched through the parsed search tool's
  # compiled SQL. Only external surface mocked is the embedder
  # (via TestStub).
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Sark.Embedder.Cache
  alias Sark.Embedder.Config, as: EmbedderConfig
  alias Sark.Plugin.DB
  alias Sark.Plugin.Embed
  alias Sark.Plugin.EmbedDrain
  alias Sark.Plugin.EmbedMigrator
  alias Sark.Plugin.Tool

  @moduletag :tmp_dir

  @stub_model "stub-model"
  @stub_provider "stub"
  @dim 16

  # ── stub embedder (the one mocked external service) ──────────────────

  defmodule TestStub do
    @moduledoc false
    @behaviour Sark.Embedder

    @impl true
    def embed(texts, %EmbedderConfig{dim: dim}) do
      Agent.update(__MODULE__, fn s -> %{s | calls: s.calls + 1} end)
      {:ok, Enum.map(texts, &deterministic_vector(&1, dim))}
    end

    def start, do: Agent.start_link(fn -> %{calls: 0} end, name: __MODULE__)
    def stop, do: Agent.stop(__MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    # Deterministic and small-magnitude — distance is 0 when the same
    # text is embedded again, so a query matching a seeded chunk text
    # surfaces that chunk first.
    def deterministic_vector(text, dim) do
      base = :erlang.phash2(text, 1_000_000)

      for i <- 0..(dim - 1) do
        :erlang.phash2({base, i}, 10_000) / 10_000.0 - 0.5
      end
    end
  end

  setup do
    Application.put_env(:sark, :embedder_adapter_overrides, %{@stub_provider => TestStub})
    Cache.clear()
    {:ok, _} = TestStub.start()

    on_exit(fn ->
      if Process.whereis(TestStub), do: TestStub.stop()
      Application.delete_env(:sark, :embedder_adapter_overrides)
      Cache.clear()
    end)

    :ok
  end

  # ── fixture helpers ──────────────────────────────────────────────────

  defp embedder, do: %EmbedderConfig{provider: @stub_provider, model: @stub_model, dim: @dim}

  defp open_raw(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readwrite)
    db
  end

  defp execute!(db, sql), do: :ok = Sqlite3.execute(db, sql)

  defp setup_plugin_db(dir, table_ddl) do
    db_path = Path.join(dir, "p.db")
    db = open_raw(db_path)
    execute!(db, "PRAGMA journal_mode = WAL")
    execute!(db, table_ddl)
    Sqlite3.close(db)

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

  defp start_pools!(plugin, db_path) do
    children =
      DB.pool_children(plugin, db_path, data_load_extensions: [Sark.SqliteVec.path()])

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
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
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
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

  defp install_embed!(plugin, db_path, embed) do
    EmbedMigrator.apply!(plugin, db_path, embed, embedder(), Sark.SqliteVec.path())
  end

  defp search_tool do
    Tool.parse!("search_nodes", %{
      "description" => "Semantic search over nodes.",
      "returns" => "results",
      "params" => %{
        "q" => %{"type" => "text", "embed" => "q_vec"},
        "limit" => %{"type" => "integer", "default" => 10, "required" => false}
      },
      "sql" =>
        "SELECT m.row_pk, m.chunk_text, ve.distance AS score " <>
          "FROM _embeddings_nodes ve " <>
          "JOIN _embeddings_nodes_meta m ON m.id = ve.rowid " <>
          "WHERE ve.embedding MATCH :q_vec AND k = :limit " <>
          "ORDER BY ve.distance"
    })
  end

  defp run_search!(plugin, tool, params) do
    {:ok, coerced} = Tool.coerce_params(tool, params)

    # Mirror what MCP.Handlers.Tool does: for every text param with
    # an `embed:` sibling, embed (cached) and bind the vector blob
    # under the sibling name.
    coerced =
      Enum.reduce(Tool.embed_pairs(tool), coerced, fn {src, sibling}, acc ->
        {:ok, vec_bin} = Sark.Embedder.embed_query(Map.fetch!(acc, src), embedder())
        Map.put(acc, sibling, {:blob, vec_bin})
      end)

    [stmt] = tool.statements
    binds = Enum.map(stmt.param_order, fn name -> Map.fetch!(coerced, name) end)

    {:ok, _cols, rows} = DB.read(plugin, stmt.compiled_sql, binds)
    rows
  end

  defp seed(plugin, rows) do
    Enum.each(rows, fn body ->
      {:ok, _} = DB.write(plugin, "INSERT INTO nodes (body) VALUES (?)", [body])
    end)
  end

  defp standard_setup(dir) do
    db_path =
      setup_plugin_db(dir, """
      CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)
      """)

    embed = embed_for("nodes", ["body"])
    install_embed!("p", db_path, embed)
    start_pools!("p", db_path)
    start_drain!("p", embed)
    :ok
  end

  # ── tests ────────────────────────────────────────────────────────────

  describe "end-to-end search via the parsed tool's compiled SQL" do
    test "exact-text query returns the matching row first (distance 0)", %{tmp_dir: dir} do
      :ok = standard_setup(dir)
      seed("p", ["apple", "banana", "cherry"])
      {:ok, 3} = EmbedDrain.drain_now("p")

      tool = search_tool()
      rows = run_search!("p", tool, %{"q" => "apple", "limit" => 3})

      assert length(rows) == 3
      [first | _] = rows
      assert first["row_pk"] == "1"
      assert first["chunk_text"] == "apple"
      assert_in_delta first["score"], 0.0, 0.0001
    end

    test "limit caps the result count", %{tmp_dir: dir} do
      :ok = standard_setup(dir)
      seed("p", ["apple", "banana", "cherry", "date", "elderberry"])
      {:ok, 5} = EmbedDrain.drain_now("p")

      tool = search_tool()
      rows = run_search!("p", tool, %{"q" => "apple", "limit" => 2})

      assert length(rows) == 2
    end
  end

  describe "cache" do
    test "second search w/ identical query text does not call the embedder", %{tmp_dir: dir} do
      :ok = standard_setup(dir)
      seed("p", ["apple", "banana"])
      {:ok, 2} = EmbedDrain.drain_now("p")

      drain_calls_after_seed = TestStub.calls()
      tool = search_tool()

      _ = run_search!("p", tool, %{"q" => "apple", "limit" => 1})
      calls_after_first_search = TestStub.calls()
      assert calls_after_first_search == drain_calls_after_seed + 1

      # Repeat the same query — should hit Cache, no embedder call.
      _ = run_search!("p", tool, %{"q" => "apple", "limit" => 1})
      assert TestStub.calls() == calls_after_first_search
    end

    test "different query text invalidates the cache hit", %{tmp_dir: dir} do
      :ok = standard_setup(dir)
      seed("p", ["apple", "banana"])
      {:ok, 2} = EmbedDrain.drain_now("p")

      drain_calls = TestStub.calls()
      tool = search_tool()

      _ = run_search!("p", tool, %{"q" => "apple", "limit" => 1})
      _ = run_search!("p", tool, %{"q" => "banana", "limit" => 1})

      # +2 embedder calls: one for "apple", one for "banana".
      assert TestStub.calls() == drain_calls + 2
    end

    test "Cache.clear forces a re-embed of the same query", %{tmp_dir: dir} do
      :ok = standard_setup(dir)
      seed("p", ["apple"])
      {:ok, 1} = EmbedDrain.drain_now("p")

      drain_calls = TestStub.calls()
      tool = search_tool()

      _ = run_search!("p", tool, %{"q" => "apple", "limit" => 1})
      assert TestStub.calls() == drain_calls + 1

      Cache.clear()

      _ = run_search!("p", tool, %{"q" => "apple", "limit" => 1})
      assert TestStub.calls() == drain_calls + 2
    end
  end

  describe "Embedder.embed_query" do
    test "miss → adapter call → cached", %{tmp_dir: _dir} do
      assert Cache.lookup(@stub_model, "hello") == :miss

      {:ok, vec_bin} = Sark.Embedder.embed_query("hello", embedder())
      assert is_binary(vec_bin)
      assert byte_size(vec_bin) == @dim * 4

      # Subsequent lookup is a hit returning the same binary.
      assert {:ok, ^vec_bin} = Cache.lookup(@stub_model, "hello")
    end
  end
end

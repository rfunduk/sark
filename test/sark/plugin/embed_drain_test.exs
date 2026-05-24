defmodule Sark.Plugin.EmbedDrainTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Sark.Embedder.Config, as: EmbedderConfig
  alias Sark.Plugin.DB
  alias Sark.Plugin.Embed
  alias Sark.Plugin.EmbedDrain
  alias Sark.Plugin.EmbedMigrator

  @moduletag :tmp_dir

  # ── stub embedder (the one external service we mock) ─────────────────

  defmodule TestStub do
    @moduledoc false
    @behaviour Sark.Embedder

    @impl true
    def embed(texts, %EmbedderConfig{dim: dim}) do
      Agent.update(__MODULE__, fn s ->
        %{s | calls: s.calls + 1, total_texts: s.total_texts + length(texts)}
      end)

      case Agent.get(__MODULE__, & &1.mode) do
        :ok ->
          {:ok, Enum.map(texts, &deterministic(&1, dim))}

        :error ->
          {:error, :stubbed_failure}

        :raise ->
          raise "stubbed embedder raised"
      end
    end

    def start,
      do: Agent.start_link(fn -> %{mode: :ok, calls: 0, total_texts: 0} end, name: __MODULE__)

    def stop, do: Agent.stop(__MODULE__)
    def set_mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))
    def state, do: Agent.get(__MODULE__, & &1)

    # Deterministic vector — same text always maps to same dim-length
    # list of small floats. Avoids randomness so tests can assert on
    # specific values when they care.
    defp deterministic(text, dim) do
      base = :erlang.phash2(text, 1_000_000)

      for i <- 0..(dim - 1) do
        :erlang.phash2({base, i}, 10_000) / 10_000.0 - 0.5
      end
    end
  end

  setup do
    {:ok, _} = TestStub.start()
    on_exit(fn -> if Process.whereis(TestStub), do: TestStub.stop() end)
    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp embedder, do: %EmbedderConfig{provider: "stub", model: "stub-model", dim: 16}

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

  defp open_raw(db_path) do
    {:ok, db} = Sqlite3.open(db_path, mode: :readwrite)
    db
  end

  defp execute!(db, sql) do
    :ok = Sqlite3.execute(db, sql)
  end

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
      DB.pool_children(plugin, db_path, data_load_extensions: [SqliteVec.path()])

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.unlink(sup)
    on_exit(fn -> safe_stop(sup, :supervisor) end)
    sup
  end

  defp start_drain!(plugin, embed, opts \\ []) do
    drain_opts =
      [
        plugin: plugin,
        embed: embed,
        embedder: embedder(),
        embedder_impl: TestStub,
        # Fast retry/escalation for tests.
        max_attempts: 3,
        backoff_base_ms: 1
      ] ++ opts

    {:ok, pid} = EmbedDrain.start_link(drain_opts)
    Process.unlink(pid)
    on_exit(fn -> safe_stop(pid, :genserver) end)
    pid
  end

  defp safe_stop(pid, kind) do
    if Process.alive?(pid) do
      try do
        case kind do
          :supervisor -> Supervisor.stop(pid)
          :genserver -> GenServer.stop(pid)
        end
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp queue_count(plugin) do
    {:ok, _, [%{"count" => c}]} =
      DB.read(plugin, "SELECT COUNT(*) AS count FROM _embed_queue", [])

    c
  end

  defp meta_rows(plugin, table) do
    {:ok, _, rows} =
      DB.read(
        plugin,
        "SELECT row_pk, field, chunk_index, content_hash, config_hash, chunk_text " <>
          "FROM _embeddings_#{table}_meta ORDER BY id",
        []
      )

    rows
  end

  defp vec_count(plugin, table) do
    {:ok, _, [%{"count" => c}]} =
      DB.read(plugin, "SELECT COUNT(*) AS count FROM _embeddings_#{table}", [])

    c
  end

  defp queue_status(plugin) do
    {:ok, _, rows} =
      DB.read(
        plugin,
        "SELECT status, attempts, last_error FROM _embed_queue ORDER BY id",
        []
      )

    rows
  end

  defp install_embed!(plugin, db_path, embed) do
    EmbedMigrator.apply!(plugin, db_path, embed, embedder(), SqliteVec.path())
  end

  defp standard_setup(dir) do
    db_path =
      setup_plugin_db(dir, """
      CREATE TABLE nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        summary TEXT,
        body TEXT
      )
      """)

    embed = embed_for("nodes", ["summary", "body"])
    install_embed!("p", db_path, embed)
    start_pools!("p", db_path)
    start_drain!("p", embed)

    {db_path, embed}
  end

  # ── tests ────────────────────────────────────────────────────────────

  describe "INSERT path" do
    test "drain embeds an inserted row, writes meta + vec0, deletes queue row", %{tmp_dir: dir} do
      {_db_path, _embed} = standard_setup(dir)

      DB.write!(
        "p",
        "INSERT INTO nodes (summary, body) VALUES (?, ?)",
        ["hi there", "lorem ipsum body"]
      )

      assert queue_count("p") == 1

      {:ok, drained} = EmbedDrain.drain_now("p")
      assert drained == 1

      # Queue cleared.
      assert queue_count("p") == 0

      # Two meta rows (one per field), one vec0 row each.
      meta = meta_rows("p", "nodes")
      assert length(meta) == 2
      fields = Enum.map(meta, & &1["field"]) |> Enum.sort()
      assert fields == ["body", "summary"]
      assert Enum.all?(meta, fn r -> r["row_pk"] == "1" end)
      assert vec_count("p", "nodes") == 2

      # Embedder was called exactly once with two texts (batched).
      st = TestStub.state()
      assert st.calls == 1
      assert st.total_texts == 2
    end

    test "multi-chunk field produces multiple meta + vec0 rows", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE docs (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT)
        """)

      embed = embed_for("docs", ["content"], chunk: %{size: 10, overlap: 2})
      install_embed!("p", db_path, embed)
      start_pools!("p", db_path)
      start_drain!("p", embed)

      # 25-byte body w/ size=10, overlap=2, stride=8 → chunks at [0..9],
      # [8..17], [16..24] = 3 chunks.
      DB.write!("p", "INSERT INTO docs (content) VALUES (?)", [String.duplicate("x", 25)])

      {:ok, 1} = EmbedDrain.drain_now("p")

      meta = meta_rows("p", "docs")
      assert length(meta) == 3
      assert Enum.map(meta, & &1["chunk_index"]) == [0, 1, 2]
      assert Enum.all?(meta, fn r -> r["field"] == "content" end)
      assert vec_count("p", "docs") == 3
    end
  end

  describe "UPDATE / content_hash skip" do
    test "no-op update (same field values) skips the embedder", %{tmp_dir: dir} do
      standard_setup(dir)

      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s1", "b1"])
      {:ok, 1} = EmbedDrain.drain_now("p")

      calls_before = TestStub.state().calls
      assert calls_before == 1

      # UPDATE that doesn't change the embedded fields. Trigger still
      # fires, queue row enqueued, but drain sees matching content_hash
      # for all chunks → embedder NOT called.
      DB.write!("p", "UPDATE nodes SET summary = 's1' WHERE id = 1", [])
      assert queue_count("p") == 1

      {:ok, 1} = EmbedDrain.drain_now("p")
      assert queue_count("p") == 0

      assert TestStub.state().calls == calls_before
    end

    test "field change re-embeds only the changed chunk(s)", %{tmp_dir: dir} do
      standard_setup(dir)

      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s1", "b1"])
      {:ok, 1} = EmbedDrain.drain_now("p")
      [_, _] = meta_rows("p", "nodes")

      calls_before = TestStub.state().calls
      texts_before = TestStub.state().total_texts

      # Only `summary` changes; `body` stays.
      DB.write!("p", "UPDATE nodes SET summary = 's2' WHERE id = 1", [])
      {:ok, 1} = EmbedDrain.drain_now("p")

      st = TestStub.state()
      assert st.calls == calls_before + 1
      assert st.total_texts == texts_before + 1, "should re-embed only summary"

      # Meta still has 2 rows, body's hash unchanged, summary's new.
      meta = meta_rows("p", "nodes") |> Enum.sort_by(& &1["field"])
      assert length(meta) == 2

      summary_text = meta |> Enum.find(&(&1["field"] == "summary")) |> Map.fetch!("chunk_text")
      body_text = meta |> Enum.find(&(&1["field"] == "body")) |> Map.fetch!("chunk_text")
      assert summary_text == "s2"
      assert body_text == "b1"

      # Still exactly 2 vectors for this row.
      assert vec_count("p", "nodes") == 2
    end
  end

  describe "DELETE path" do
    test "deleting a source row drops its vectors + meta", %{tmp_dir: dir} do
      standard_setup(dir)

      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s", "b"])
      {:ok, 1} = EmbedDrain.drain_now("p")
      assert vec_count("p", "nodes") == 2

      DB.write!("p", "DELETE FROM nodes WHERE id = 1", [])
      {:ok, 1} = EmbedDrain.drain_now("p")

      assert vec_count("p", "nodes") == 0
      assert meta_rows("p", "nodes") == []
      assert queue_count("p") == 0
    end

    test "drain of INSERT for a row that was later deleted at source treats it as delete",
         %{tmp_dir: dir} do
      standard_setup(dir)

      # Insert + immediately delete — both queue rows pending.
      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s", "b"])
      DB.write!("p", "DELETE FROM nodes WHERE id = 1", [])
      assert queue_count("p") == 2

      {:ok, 2} = EmbedDrain.drain_now("p")

      # INSERT queue row: source gone → treated as delete (no vectors
      # created). DELETE queue row: nothing to delete.
      assert vec_count("p", "nodes") == 0
      assert meta_rows("p", "nodes") == []
      assert queue_count("p") == 0
    end
  end

  describe "failure handling" do
    test "embedder error bumps attempts, leaves status pending until threshold", %{tmp_dir: dir} do
      standard_setup(dir)
      TestStub.set_mode(:error)

      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s", "b"])

      # First attempt → attempts=1, still pending.
      {:ok, 1} = EmbedDrain.drain_now("p")
      [%{"status" => s, "attempts" => a, "last_error" => err}] = queue_status("p")
      assert s == "pending"
      assert a == 1
      assert err =~ "stubbed_failure"

      # Second attempt → attempts=2, still pending.
      {:ok, 1} = EmbedDrain.drain_now("p")
      [%{"status" => "pending", "attempts" => 2}] = queue_status("p")

      # Third attempt → reaches max_attempts (3) → escalates to failed.
      {:ok, 1} = EmbedDrain.drain_now("p")
      [%{"status" => "failed", "attempts" => 3}] = queue_status("p")

      assert vec_count("p", "nodes") == 0
    end

    test "failed rows are not picked up by subsequent drains", %{tmp_dir: dir} do
      standard_setup(dir)
      TestStub.set_mode(:error)

      DB.write!("p", "INSERT INTO nodes (summary, body) VALUES (?, ?)", ["s", "b"])
      # Drive to failed (3 attempts w/ max_attempts=3).
      {:ok, 1} = EmbedDrain.drain_now("p")
      {:ok, 1} = EmbedDrain.drain_now("p")
      {:ok, 1} = EmbedDrain.drain_now("p")
      [%{"status" => "failed"}] = queue_status("p")

      # Switch stub back to ok — failed rows still don't get retried.
      TestStub.set_mode(:ok)
      {:ok, 0} = EmbedDrain.drain_now("p")
      assert vec_count("p", "nodes") == 0
    end
  end

  describe "orphan queue rows" do
    test "queue row for a table not in current embed config is discarded", %{tmp_dir: dir} do
      # Boot with two tables in embed config.
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);
        CREATE TABLE docs  (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT);
        """)

      embed_both =
        embed_for("nodes", ["body"]) |> Map.merge(embed_for("docs", ["content"]))

      install_embed!("p", db_path, embed_both)
      start_pools!("p", db_path)

      # Make queue rows for both tables via real triggers.
      DB.write!("p", "INSERT INTO nodes (body) VALUES ('a')", [])
      DB.write!("p", "INSERT INTO docs  (content) VALUES ('b')", [])
      assert queue_count("p") == 2

      # Start drain with only `nodes` in its embed map (simulates an
      # operator removing `docs` from `embed:` between trigger fire
      # and drain).
      embed_only_nodes = embed_for("nodes", ["body"])
      start_drain!("p", embed_only_nodes)

      {:ok, 2} = EmbedDrain.drain_now("p")
      assert queue_count("p") == 0

      # Nodes got embedded; docs queue row was simply discarded.
      assert vec_count("p", "nodes") == 1
      st = TestStub.state()
      assert st.calls == 1
      assert st.total_texts == 1
    end
  end

  describe "custom pk + where:" do
    test "custom pk is honored when loading source rows", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE docs (uri TEXT PRIMARY KEY, content TEXT)
        """)

      embed = embed_for("docs", ["content"], pk: "uri")
      install_embed!("p", db_path, embed)
      start_pools!("p", db_path)
      start_drain!("p", embed)

      DB.write!("p", "INSERT INTO docs (uri, content) VALUES ('/a', 'hello')", [])
      {:ok, 1} = EmbedDrain.drain_now("p")

      [meta] = meta_rows("p", "docs")
      assert meta["row_pk"] == "/a"
      assert vec_count("p", "docs") == 1
    end

    test "where: predicate filters out rows from embedding", %{tmp_dir: dir} do
      db_path =
        setup_plugin_db(dir, """
        CREATE TABLE notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          body TEXT,
          status TEXT NOT NULL DEFAULT 'open'
        )
        """)

      embed = embed_for("notes", ["body"], where: "status != 'archived'")
      install_embed!("p", db_path, embed)
      start_pools!("p", db_path)
      start_drain!("p", embed)

      DB.write!("p", "INSERT INTO notes (body, status) VALUES ('x', 'archived')", [])
      {:ok, 1} = EmbedDrain.drain_now("p")

      # Trigger enqueued; drain sees the where: predicate excludes the
      # row → treats as delete (no vectors land).
      assert vec_count("p", "notes") == 0
      assert meta_rows("p", "notes") == []
      assert queue_count("p") == 0
    end
  end
end

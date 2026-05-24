defmodule Sark.PluginTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../fixtures/plugins/kv", __DIR__)

  # Generate a unique plugin name per test so registered process names
  # (pool writers, MCP router module, etc) don't collide when tests run
  # async. Pool count grows linearly with tests in a session; in
  # practice the suite is small enough not to matter.
  defp unique_name, do: "kv_#{System.unique_integer([:positive])}"

  defp start_plugin!(spec, data_dir) do
    start_supervised!({Plugin, spec: spec, data_dir: data_dir}, id: spec.name)
  end

  test "boots kv plugin and round-trips a write/read", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    db_path = Path.join(dir, "#{name}.db")
    assert File.exists?(db_path)
    assert File.exists?(Path.join(dir, "#{name}.sark.db"))

    {:ok, _} =
      DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["greeting", "hello"])

    assert {:ok, ["key", "value"], [%{"key" => "greeting", "value" => "hello"}]} =
             DB.read(spec.name, "SELECT key, value FROM kv WHERE key = ?", ["greeting"])
  end

  test "schema apply is idempotent across restarts", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)

    pid1 = start_plugin!(spec, dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
    stop_supervised!(spec.name)
    refute Process.alive?(pid1)

    _pid2 = start_plugin!(spec, dir)

    assert {:ok, ["key", "value"], [%{"key" => "a", "value" => "1"}]} =
             DB.read(spec.name, "SELECT key, value FROM kv", [])
  end

  test "reader pool refuses writes (query_only)", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    assert {:error, %Exqlite.Error{message: msg}} =
             Exqlite.query(
               DB.reader_name(spec.name),
               "INSERT INTO kv (key, value) VALUES (?, ?)",
               ["x", "y"]
             )

    assert msg =~ "read" or msg =~ "query_only" or msg =~ "readonly"
  end

  test "WAL mode is enabled on the file", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    assert {:ok, ["journal_mode"], [%{"journal_mode" => "wal"}]} =
             DB.read(spec.name, "PRAGMA journal_mode", [])
  end

  test "auto-decodes json_object / json_group_array columns", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["b", "2"])

    sql = """
    SELECT json_object('count', COUNT(*)) AS meta,
           json_group_array(json_object('key', key, 'value', value)) AS items
    FROM kv;
    """

    assert {:ok, _, [%{"meta" => %{"count" => 2}, "items" => items}]} =
             DB.read(spec.name, sql, [])

    assert [%{"key" => "a", "value" => "1"}, %{"key" => "b", "value" => "2"}] = items
  end

  test "sark DB pools are reachable under their kind-tagged names", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    # Verify both writer + reader pools for the sark DB are alive.
    assert is_pid(Process.whereis(DB.writer_name(spec.name, :sark)))
    assert is_pid(Process.whereis(DB.reader_name(spec.name, :sark)))

    # And distinct from the data-DB pools.
    refute DB.writer_name(spec.name, :sark) == DB.writer_name(spec.name, :data)
  end

  test "sark-internal migrations populate _pipeline_log + _pipeline_step_log in the sark DB",
       %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    # Tracker reflects applied internal migrations.
    assert {:ok, _, [%{"version" => 1}, %{"version" => 2}]} =
             DB.sark_read(spec.name, "SELECT version FROM _migrations ORDER BY version", [])

    # Tables exist + are queryable on the sark DB.
    assert {:ok, _, []} = DB.sark_read(spec.name, "SELECT * FROM _pipeline_log", [])
    assert {:ok, _, []} = DB.sark_read(spec.name, "SELECT * FROM _pipeline_step_log", [])
    assert {:ok, _, []} = DB.sark_read(spec.name, "SELECT * FROM _pipeline_state", [])
  end

  test "leaves non-JSON strings starting with [ or { untouched", %{tmp_dir: dir} do
    name = unique_name()
    spec = Loader.load!(name, @kv_fixture)
    start_plugin!(spec, dir)

    {:ok, _} =
      DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["x", "[not json"])

    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["y", "{also no"])

    assert {:ok, _, rows} = DB.read(spec.name, "SELECT key, value FROM kv ORDER BY key", [])
    assert [%{"value" => "[not json"}, %{"value" => "{also no"}] = rows
  end
end

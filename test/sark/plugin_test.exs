defmodule Sark.PluginTest do
  use ExUnit.Case, async: false

  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../fixtures/plugins/kv", __DIR__)

  defp start_plugin!(spec, data_dir) do
    pid = start_supervised!({Plugin, spec: spec, data_dir: data_dir})
    pid
  end

  test "boots kv plugin and round-trips a write/read", %{tmp_dir: dir} do
    spec = Loader.load!(@kv_fixture)
    start_plugin!(spec, dir)

    db_path = Path.join(dir, "kv.db")
    assert File.exists?(db_path)

    {:ok, _} =
      DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["greeting", "hello"])

    assert {:ok, [%{"key" => "greeting", "value" => "hello"}]} =
             DB.read(spec.name, "SELECT key, value FROM kv WHERE key = ?", ["greeting"])
  end

  test "schema apply is idempotent across restarts", %{tmp_dir: dir} do
    spec = Loader.load!(@kv_fixture)

    pid1 = start_plugin!(spec, dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
    stop_supervised!(Plugin)
    refute Process.alive?(pid1)

    _pid2 = start_plugin!(spec, dir)

    assert {:ok, [%{"key" => "a", "value" => "1"}]} =
             DB.read(spec.name, "SELECT key, value FROM kv", [])
  end

  test "reader pool refuses writes (query_only)", %{tmp_dir: dir} do
    spec = Loader.load!(@kv_fixture)
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
    spec = Loader.load!(@kv_fixture)
    start_plugin!(spec, dir)

    assert {:ok, [%{"journal_mode" => "wal"}]} =
             DB.read(spec.name, "PRAGMA journal_mode", [])
  end
end

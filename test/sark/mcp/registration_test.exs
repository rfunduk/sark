defmodule Sark.MCP.RegistrationTest do
  use ExUnit.Case, async: false

  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.MCP.Router
  alias Sark.Plugin
  alias Sark.Plugin.DB
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  setup do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    # Clear Phantom's persistent_term so tools registered in earlier tests
    # don't bleed in.
    :persistent_term.put({Phantom, Router, :tools}, [])
    :persistent_term.put({Phantom, Router, :initialized}, false)

    :ok
  end

  defp boot_kv!(dir) do
    spec = Loader.load!(@kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})
    spec
  end

  test "registers per-query tools + catalog + sql_query in Phantom cache", %{tmp_dir: dir} do
    boot_kv!(dir)

    tools = Phantom.Cache.list(nil, Router, :tools)
    names = Enum.map(tools, & &1.name) |> Enum.sort()

    assert "get" in names
    assert "find" in names
    assert "list" in names
    assert "list_table" in names
    assert "total" in names
    assert "put" in names
    assert "catalog" in names
    assert "sql_query" in names
    assert "ping" in names
  end

  test "stores parsed queries in Sark.MCP.Registry", %{tmp_dir: dir} do
    boot_kv!(dir)

    queries = SarkRegistry.list_for_plugin("kv")
    names = Enum.map(queries, & &1.name) |> Enum.sort()

    assert names == [
             :add_note,
             :delete,
             :find,
             :get,
             :list,
             :list_table,
             :put,
             :put_strict,
             :total
           ]
  end

  test "get round-trips a row", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, _} =
      DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["alpha", "one"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.get(%{"key" => "alpha"}, :session)

    assert text =~ "alpha"
    assert text =~ "one"
  end

  test "list renders bullets", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["a", "1"])
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["b", "2"])

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, %{content: [%{type: :text, text: text}]}, _} = mod.list(%{}, :session)

    assert text =~ "- key: a"
    assert text =~ "- key: b"
  end

  test "find with template renders the row", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["k", "v"])

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, %{content: [%{type: :text, text: text}]}, _} = mod.find(%{"key" => "k"}, :session)

    assert text =~ "key: k"
    assert text =~ "value: v"
  end

  test "total returns scalar count as JSON", %{tmp_dir: dir} do
    spec = boot_kv!(dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["x", "y"])

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, %{content: [%{type: :text, text: text}]}, _} = mod.total(%{}, :session)

    assert text == "1"
  end

  test "put writes and returns the inserted key", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.put(%{"key" => "x", "value" => "y"}, :session)

    # write format defaults to :json; one_row → returns the row map
    assert text =~ "x"

    # confirm round-trip via DB
    {:ok, _, [%{"value" => "y"}]} =
      DB.read(spec.name, "SELECT value FROM kv WHERE key = ?", ["x"])
  end

  test "put broadcasts a write event on Sark.MCP.EventBus", %{tmp_dir: dir} do
    boot_kv!(dir)

    :ok = Sark.MCP.EventBus.subscribe("kv.put")

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, _, _} = mod.put(%{"key" => "k", "value" => "v"}, :session)

    assert_receive {:sark_write, "kv", :put, %{params: %{"key" => "k"}}}, 200
  end

  test "get validation error on missing required param", %{tmp_dir: dir} do
    boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.get(%{}, :session)

    assert text =~ "validation"
    assert text =~ "key"
  end

  test "catalog returns structured doc with queries", %{tmp_dir: dir} do
    boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, %{structuredContent: doc}, _} = mod.catalog(%{}, :session)

    assert doc.name == "kv"
    assert doc.title == "KV"
    assert [%{version: 1, sql: sql}] = doc.migrations
    assert sql =~ "CREATE TABLE"
    query_names = Enum.map(doc.queries, & &1.name) |> Enum.sort()

    assert query_names ==
             [
               "add_note",
               "delete",
               "find",
               "get",
               "list",
               "list_table",
               "put",
               "put_strict",
               "total"
             ]
  end

  test "sql_query allows SELECT, rejects DELETE", %{tmp_dir: dir} do
    spec = boot_kv!(dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["q", "r"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: ok_text}]}, _} =
      mod.sql_query(%{"sql" => "SELECT key FROM kv"}, :session)

    assert ok_text =~ "q"

    {:reply, %{content: [%{type: :text, text: bad_text}], isError: true}, _} =
      mod.sql_query(%{"sql" => "DELETE FROM kv"}, :session)

    assert bad_text =~ "only SELECT"
  end

  test "put_strict surfaces constraint error class on duplicate key", %{tmp_dir: dir} do
    spec = boot_kv!(dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["dup", "1"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.put_strict(%{"key" => "dup", "value" => "2"}, :session)

    assert text =~ "constraint"
  end

  test "delete returns count via :count returns", %{tmp_dir: dir} do
    spec = boot_kv!(dir)
    {:ok, _} = DB.write(spec.name, "INSERT INTO kv (key, value) VALUES (?, ?)", ["d", "1"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.delete(%{"key" => "d"}, :session)

    assert text =~ "1"
  end

  test "patch_text happy path swaps the value", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(spec.name, "INSERT INTO notes (body) VALUES (?) RETURNING id", ["alpha"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "alpha", "new" => "beta"},
        :session
      )

    assert text =~ "true"

    {:ok, _, [%{"body" => "beta"}]} =
      DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [id])
  end

  test "patch_text mismatch leaves row untouched", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(spec.name, "INSERT INTO notes (body) VALUES (?) RETURNING id", ["alpha"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "WRONG", "new" => "beta"},
        :session
      )

    assert text =~ "mismatch"

    {:ok, _, [%{"body" => "alpha"}]} =
      DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [id])
  end

  test "patch_text rejects bad identifier", %{tmp_dir: dir} do
    boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.patch_text(
        %{
          "table" => "notes; DROP TABLE notes;--",
          "id" => 1,
          "col" => "body",
          "old" => "a",
          "new" => "b"
        },
        :session
      )

    assert text =~ "identifier pattern"
  end

  test "patch_text not found", %{tmp_dir: dir} do
    boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => 9999, "col" => "body", "old" => "x", "new" => "y"},
        :session
      )

    assert text =~ "not found"
  end

  test "patch_text broadcasts a write event", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(spec.name, "INSERT INTO notes (body) VALUES (?) RETURNING id", ["a"])

    :ok = Sark.MCP.EventBus.subscribe("kv.patch_text")

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, _, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "a", "new" => "b"},
        :session
      )

    assert_receive {:sark_write, "kv", :patch_text, %{params: %{"table" => "notes"}}}, 200
  end

  test "patch_text tool registered in Phantom cache", %{tmp_dir: dir} do
    boot_kv!(dir)

    tools = Phantom.Cache.list(nil, Router, :tools)
    names = Enum.map(tools, & &1.name)

    assert "patch_text" in names
  end
end

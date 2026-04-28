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

    assert "kv_get" in names
    assert "kv_find" in names
    assert "kv_list" in names
    assert "kv_list_table" in names
    assert "kv_total" in names
    assert "kv_put" in names
    assert "kv_catalog" in names
    assert "kv_sql_query" in names
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
             :reset_note,
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

  test "catalog returns live schema + queries", %{tmp_dir: dir} do
    boot_kv!(dir)

    mod = Sark.MCP.Registration.handler_module("kv")
    {:reply, %{structuredContent: doc}, _} = mod.catalog(%{}, :session)

    assert doc.name == "kv"

    schema_names = Enum.map(doc.schema, & &1.name)
    assert "kv" in schema_names
    assert "notes" in schema_names

    kv_entry = Enum.find(doc.schema, &(&1.name == "kv"))
    assert kv_entry.type == "table"
    assert kv_entry.sql =~ "CREATE TABLE"

    refute Enum.any?(doc.schema, fn e -> String.starts_with?(e.name, "_sark_") end)
    refute Enum.any?(doc.schema, fn e -> String.starts_with?(e.name, "sqlite_") end)

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
               "reset_note",
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

  test "multi-statement write runs all statements in order", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, _} = DB.write(spec.name, "INSERT INTO notes (body) VALUES (?)", ["hello"])
    {:ok, _} = DB.write(spec.name, "INSERT INTO notes (body) VALUES (?)", ["hello"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.reset_note(%{"body" => "hello"}, :session)

    assert text =~ "\"id\""

    {:ok, _, [%{"n" => 1}]} =
      DB.read(spec.name, "SELECT COUNT(*) AS n FROM notes WHERE body = ?", ["hello"])
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

  test "patch_text substring not found leaves row untouched", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(spec.name, "INSERT INTO notes (body) VALUES (?) RETURNING id", ["alpha"])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}], isError: true}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "WRONG", "new" => "beta"},
        :session
      )

    assert text =~ "substring not found"

    {:ok, _, [%{"body" => "alpha"}]} =
      DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [id])
  end

  test "patch_text replaces a substring inside larger text", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(
        spec.name,
        "INSERT INTO notes (body) VALUES (?) RETURNING id",
        ["There are 50 servers in the pool."]
      )

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "50", "new" => "100"},
        :session
      )

    assert text =~ "\"replacements\":1"

    {:ok, _, [%{"body" => "There are 100 servers in the pool."}]} =
      DB.read(spec.name, "SELECT body FROM notes WHERE id = ?", [id])
  end

  test "patch_text replaces every occurrence", %{tmp_dir: dir} do
    spec = boot_kv!(dir)

    {:ok, %{rows: [[id]]}} =
      DB.write(spec.name, "INSERT INTO notes (body) VALUES (?) RETURNING id", [
        "foo bar foo baz foo"
      ])

    mod = Sark.MCP.Registration.handler_module("kv")

    {:reply, %{content: [%{type: :text, text: text}]}, _} =
      mod.patch_text(
        %{"table" => "notes", "id" => id, "col" => "body", "old" => "foo", "new" => "qux"},
        :session
      )

    assert text =~ "\"replacements\":3"

    {:ok, _, [%{"body" => "qux bar qux baz qux"}]} =
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

    assert "kv_patch_text" in names
  end
end

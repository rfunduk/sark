defmodule Sark.MCP.InternalTest do
  use ExUnit.Case, async: false

  alias Sark.MCP.Internal
  alias Sark.Plugin
  alias Sark.Plugin.Loader
  alias Sark.Plugin.Spec

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})
    {:ok, spec: spec}
  end

  test "call_tool routes to a canned query", %{spec: _spec} do
    {:ok, _} = Internal.call_tool("kv", "put", %{"key" => "x", "value" => "1"})

    assert {:ok, text} = Internal.call_tool("kv", "list", %{})
    assert text =~ "x"
  end

  test "call_tool returns error tuple on validation failure" do
    assert {:error, msg} = Internal.call_tool("kv", "put", %{"key" => "x"})
    assert msg =~ "validation"
  end

  test "call_tool routes to patch_text built-in" do
    {:ok, _} =
      Internal.call_tool("kv", "add_note", %{"body" => "hello world, hello again"})

    {:ok, _} =
      Internal.call_tool("kv", "patch_text", %{
        "table" => "notes",
        "id" => 1,
        "col" => "body",
        "old" => "hello",
        "new" => "ciao"
      })

    assert {:ok, _} =
             Internal.call_tool("kv", "sql_query", %{
               "sql" => "SELECT body FROM notes WHERE id = 1"
             })
  end

  test "tools_for builds JSON schemas for query allowlist", %{spec: spec} do
    tools = Internal.tools_for(spec, ["list", "get"])

    names = Enum.map(tools, & &1.name) |> Enum.sort()
    assert names == ["get", "list"]

    Enum.each(tools, fn t ->
      assert is_binary(t.description)
      assert is_map(t.input_schema)
    end)
  end

  test "tools_for includes built-in patch_text", %{spec: spec} do
    [tool] = Internal.tools_for(spec, ["patch_text"])
    assert tool.name == "patch_text"
    assert "old" in tool.input_schema.required
  end

  test "tools_for raises on unknown tool", %{spec: spec} do
    assert_raise ArgumentError, ~r/unknown tool `nope`/, fn ->
      Internal.tools_for(spec, ["nope"])
    end
  end

  test "tools_for refuses sql_query/catalog when allow_sql is false", %{spec: spec} do
    spec = %Spec{spec | allow_sql: false}

    assert_raise ArgumentError, ~r/unknown tool `sql_query`/, fn ->
      Internal.tools_for(spec, ["sql_query"])
    end
  end

  test "tools_for surfaces sql_query/catalog when allow_sql is true", %{spec: spec} do
    spec = %Spec{spec | allow_sql: true}
    tools = Internal.tools_for(spec, ["catalog", "sql_query"])
    names = Enum.map(tools, & &1.name) |> Enum.sort()
    assert names == ["catalog", "sql_query"]
  end

  test "internal queries are addressable from Internal even though Phantom doesn't expose them",
       %{spec: spec} do
    [tool] = Internal.tools_for(spec, ["secret_note"])
    assert tool.name == "secret_note"

    {:ok, _} = Internal.call_tool("kv", "secret_note", %{"body" => "ssh"})
  end

  test "catalog filters internal queries out of public response", %{spec: spec} do
    spec = %Spec{spec | allow_sql: true}
    {:ok, text} = Internal.call_tool("kv", "catalog", %{})
    decoded = Jason.decode!(text)

    query_names = Enum.map(decoded["queries"], & &1["name"])
    refute "secret_note" in query_names
    assert "add_note" in query_names

    _ = spec
  end
end

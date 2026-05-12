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

  test "call_tool runs `reject:` pre-flight and short-circuits on first hit" do
    # Reserved-prefix reject fires before the duplicate-key reject.
    assert {:error, msg} =
             Internal.call_tool("kv", "put_unique", %{"key" => "_admin", "value" => "v"})

    assert msg =~ "rejected:"
    assert msg =~ "reserved prefix"
    assert msg =~ "_admin"

    # Successful insert (no reject hit).
    assert {:ok, _} = Internal.call_tool("kv", "put_unique", %{"key" => "fresh", "value" => "v"})

    # Second insert with same key trips the duplicate-key reject.
    assert {:error, msg2} =
             Internal.call_tool("kv", "put_unique", %{"key" => "fresh", "value" => "v2"})

    assert msg2 =~ "rejected:"
    assert msg2 =~ "already exists"
    assert msg2 =~ "fresh"

    # Confirm the rejected insert did not run — value still 'v'.
    assert {:ok, text} = Internal.call_tool("kv", "get", %{"key" => "fresh"})
    assert text =~ "v"
    refute text =~ "v2"
  end

  test "reject message renders booleans as true/false, not 1/0" do
    assert {:error, msg} = Internal.call_tool("kv", "bool_reject_demo", %{"flag" => true})
    assert msg =~ "rejected:"
    assert msg =~ "got flag=true"
    refute msg =~ "got flag=1"

    # false → no reject; query proceeds.
    assert {:ok, _} = Internal.call_tool("kv", "bool_reject_demo", %{"flag" => false})
  end

  test "call_tool routes to sark_patch built-in" do
    {:ok, _} =
      Internal.call_tool("kv", "add_note", %{"body" => "hello world, hello again"})

    {:ok, _} =
      Internal.call_tool("kv", "sark_patch", %{
        "table" => "notes",
        "id" => 1,
        "col" => "body",
        "old" => "hello",
        "new" => "ciao"
      })

    assert {:ok, _} =
             Internal.call_tool("kv", "sark_sql", %{
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

  test "tools_for includes built-in sark_patch", %{spec: spec} do
    [tool] = Internal.tools_for(spec, ["sark_patch"])
    assert tool.name == "sark_patch"
    assert "old" in tool.input_schema.required
  end

  test "tools_for raises on unknown tool", %{spec: spec} do
    assert_raise ArgumentError, ~r/unknown tool `nope`/, fn ->
      Internal.tools_for(spec, ["nope"])
    end
  end

  test "tools_for refuses sark_sql/sark_catalog when allow_sql is false", %{spec: spec} do
    spec = %Spec{spec | allow_sql: false}

    assert_raise ArgumentError, ~r/unknown tool `sark_sql`/, fn ->
      Internal.tools_for(spec, ["sark_sql"])
    end
  end

  test "tools_for surfaces sark_sql/sark_catalog when allow_sql is true", %{spec: spec} do
    spec = %Spec{spec | allow_sql: true}
    tools = Internal.tools_for(spec, ["sark_catalog", "sark_sql"])
    names = Enum.map(tools, & &1.name) |> Enum.sort()
    assert names == ["sark_catalog", "sark_sql"]
  end

  test "internal queries are addressable from Internal even though Phantom doesn't expose them",
       %{spec: spec} do
    [tool] = Internal.tools_for(spec, ["secret_note"])
    assert tool.name == "secret_note"

    {:ok, _} = Internal.call_tool("kv", "secret_note", %{"body" => "ssh"})
  end

  test "catalog filters internal queries out of public response", %{spec: spec} do
    spec = %Spec{spec | allow_sql: true}
    {:ok, text} = Internal.call_tool("kv", "sark_catalog", %{})
    decoded = Jason.decode!(text)

    query_names = Enum.map(decoded["queries"], & &1["name"])
    refute "secret_note" in query_names
    assert "add_note" in query_names

    _ = spec
  end
end

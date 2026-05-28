defmodule Sark.MCP.RegistrationAllowlistTest do
  use ExUnit.Case, async: false

  alias Sark.MCP.Registration
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Plugin
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  setup do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    :ok
  end

  defp boot_kv!(dir) do
    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})
    spec
  end

  defp conn_with_entry(entry) do
    %Plug.Conn{}
    |> Plug.Conn.assign(:plugin, "kv")
    |> Plug.Conn.assign(:token_name, "test")
    |> Plug.Conn.assign(:token_entry, entry)
  end

  defp session, do: %Phantom.Session{id: "test", router: nil, allowed_tools: nil}

  test "no token_entry assign → session left untouched", %{tmp_dir: dir} do
    boot_kv!(dir)
    s = session()
    conn = %Plug.Conn{}
    assert Registration.apply_token_allowlist(s, conn, "kv") == s
  end

  test "`:all` entry → no filter applied (allowed_tools stays nil)", %{tmp_dir: dir} do
    boot_kv!(dir)
    conn = conn_with_entry(%{name: "t", allowed: :all})
    out = Registration.apply_token_allowlist(session(), conn, "kv")
    assert out.allowed_tools == nil
  end

  test "plugin `:all` (bare name) → no filter applied", %{tmp_dir: dir} do
    boot_kv!(dir)
    conn = conn_with_entry(%{name: "t", allowed: %{"kv" => :all}})
    out = Registration.apply_token_allowlist(session(), conn, "kv")
    assert out.allowed_tools == nil
  end

  test "single block with positives → allowed_tools is filtered tool names", %{tmp_dir: dir} do
    boot_kv!(dir)
    # `find`, `list` are real kv queries; `nope_%` matches nothing.
    block = %{
      pos: [~r/\Afind\z/, ~r/\Alist\z/, ~r/\Anope_.*\z/],
      neg: []
    }

    conn = conn_with_entry(%{name: "t", allowed: %{"kv" => [block]}})

    out = Registration.apply_token_allowlist(session(), conn, "kv")
    assert Enum.sort(out.allowed_tools) == ["find", "list"]
  end

  test "glob `sark_%` matches every built-in but no queries", %{tmp_dir: dir} do
    boot_kv!(dir)
    block = %{pos: [~r/\Asark_.*\z/], neg: []}
    conn = conn_with_entry(%{name: "t", allowed: %{"kv" => [block]}})
    out = Registration.apply_token_allowlist(session(), conn, "kv")
    # kv fixture has allow_sql true, so sark_catalog + sark_sql registered.
    sorted = Enum.sort(out.allowed_tools)
    assert "sark_patch" in sorted
    assert "sark_catalog" in sorted
    assert "sark_sql" in sorted
    refute Enum.any?(sorted, &(not String.starts_with?(&1, "sark_")))
  end

  test "block with negation → matches pos minus neg", %{tmp_dir: dir} do
    boot_kv!(dir)
    # all built-ins except sark_sql
    block = %{pos: [~r/\Asark_.*\z/], neg: [~r/\Asark_sql\z/]}
    conn = conn_with_entry(%{name: "t", allowed: %{"kv" => [block]}})
    out = Registration.apply_token_allowlist(session(), conn, "kv")
    sorted = Enum.sort(out.allowed_tools)
    assert "sark_catalog" in sorted
    assert "sark_patch" in sorted
    refute "sark_sql" in sorted
  end

  test "plugin not present in entry → empty allowlist (every call denied)",
       %{tmp_dir: dir} do
    boot_kv!(dir)
    conn = conn_with_entry(%{name: "t", allowed: %{"kb" => :all}})
    out = Registration.apply_token_allowlist(session(), conn, "kv")
    assert out.allowed_tools == []
  end
end

defmodule Sark.EndpointTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Sark.AuthRegistry
  alias Sark.Endpoint
  alias Sark.MCP.Registration
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Plugin
  alias Sark.Plugin.Loader

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../fixtures/plugins/kv", __DIR__)

  setup %{tmp_dir: dir} do
    if pid = Process.whereis(AuthRegistry) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 5_000)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    start_supervised!({AuthRegistry, %{"sk-good" => %{name: "default", allowed: :all}}})

    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "metadata route returns RFC 9728 JSON for a known plugin" do
    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    doc = Jason.decode!(conn.resp_body)
    assert doc["resource"] =~ ~r{://[^/]+/kv/mcp$}
  end

  test "metadata route 404s for an unknown plugin" do
    conn = call(conn(:get, "/ghost/.well-known/oauth-protected-resource"))
    assert conn.status == 404
  end

  test "metadata route is reachable without a bearer token" do
    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))
    refute conn.halted
    assert conn.status == 200
  end

  test "metadata resource honors the configured external url when set" do
    prior = Application.get_env(:sark, :url)
    Application.put_env(:sark, :url, "https://sark.example.com")
    on_exit(fn -> Application.put_env(:sark, :url, prior) end)

    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))
    doc = Jason.decode!(conn.resp_body)
    assert doc["resource"] == "https://sark.example.com/kv/mcp"
  end
end

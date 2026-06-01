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

  test "metadata doc advertises sark itself as auth server in broker mode" do
    idp = %Sark.Config.IdP{
      issuer: "https://accounts.google.com",
      audience: "sark-test"
    }

    prior_idp = Application.get_env(:sark, :idp)
    prior_url = Application.get_env(:sark, :url)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :url, "https://sark.example.com")

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :url, prior_url)
    end)

    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))
    doc = Jason.decode!(conn.resp_body)

    assert doc["authorization_servers"] == ["https://sark.example.com"]
    assert doc["bearer_methods_supported"] == ["header", "query"]
    assert doc["scopes_supported"] == ["openid", "email", "profile"]
  end

  test "auth-server metadata advertises broker endpoints" do
    idp = %Sark.Config.IdP{
      issuer: "https://accounts.google.com",
      audience: "sark-test"
    }

    prior_idp = Application.get_env(:sark, :idp)
    prior_url = Application.get_env(:sark, :url)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :url, "https://sark.example.com")

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :url, prior_url)
    end)

    conn = call(conn(:get, "/.well-known/oauth-authorization-server"))
    assert conn.status == 200

    doc = Jason.decode!(conn.resp_body)
    assert doc["issuer"] == "https://accounts.google.com"
    assert doc["authorization_endpoint"] == "https://sark.example.com/oauth/authorize"
    assert doc["token_endpoint"] == "https://sark.example.com/oauth/token"
    assert doc["registration_endpoint"] == "https://sark.example.com/oauth/register"
    assert doc["code_challenge_methods_supported"] == ["S256"]
  end

  describe "/oauth/register (RFC 7591 DCR stub)" do
    defp put_idp(idp) do
      prior = Application.get_env(:sark, :idp)
      Application.put_env(:sark, :idp, idp)
      on_exit(fn -> Application.put_env(:sark, :idp, prior) end)
    end

    defp register(body) do
      conn(:post, "/oauth/register", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()
    end

    test "returns the configured client_id, echoes redirect_uris, advertises none" do
      put_idp(%Sark.Config.IdP{
        issuer: "https://accounts.google.com",
        audience: "sark-test",
        client_id: "the-shared-client",
        client_secret: "shh"
      })

      conn = register(%{"redirect_uris" => ["http://localhost:7777/callback"]})

      assert conn.status == 201
      doc = Jason.decode!(conn.resp_body)
      assert doc["client_id"] == "the-shared-client"
      assert doc["token_endpoint_auth_method"] == "none"
      assert doc["redirect_uris"] == ["http://localhost:7777/callback"]
      refute Map.has_key?(doc, "client_secret")
      assert is_integer(doc["client_id_issued_at"])
    end

    test "is reachable without a bearer token" do
      put_idp(%Sark.Config.IdP{
        issuer: "https://accounts.google.com",
        audience: "sark-test",
        client_id: "the-shared-client"
      })

      conn = register(%{})
      refute conn.halted
      assert conn.status == 201
    end

    test "errors when idp has no client_id configured" do
      put_idp(%Sark.Config.IdP{
        issuer: "https://accounts.google.com",
        audience: "sark-test"
      })

      conn = register(%{})
      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "registration_failed"
    end

    test "errors in bearer-only deployment (no idp)" do
      put_idp(nil)

      conn = register(%{})
      assert conn.status == 502
    end
  end

  test "auth-server metadata 404s in bearer-only deployment" do
    prior = Application.get_env(:sark, :idp)
    Application.put_env(:sark, :idp, nil)
    on_exit(fn -> Application.put_env(:sark, :idp, prior) end)

    conn = call(conn(:get, "/.well-known/oauth-authorization-server"))
    assert conn.status == 404
  end

  test "metadata doc omits authorization_servers in bearer-only deployment" do
    prior = Application.get_env(:sark, :idp)
    Application.put_env(:sark, :idp, nil)
    on_exit(fn -> Application.put_env(:sark, :idp, prior) end)

    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))
    doc = Jason.decode!(conn.resp_body)

    refute Map.has_key?(doc, "authorization_servers")
  end
end

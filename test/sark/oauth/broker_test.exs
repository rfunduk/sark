defmodule Sark.OAuth.BrokerTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Sark.AuthRegistry
  alias Sark.Endpoint
  alias Sark.MCP.Registration
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.Plugin
  alias Sark.Plugin.Loader
  alias Sark.Test.JWTFixture

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)

  @issuer "https://idp.example.com"
  @authorize_endpoint "https://idp.example.com/authorize"
  @token_endpoint "https://idp.example.com/token"
  @jwks_uri "https://idp.example.com/jwks"
  @client_id "test-client-id"
  @client_secret "test-client-secret"

  setup %{tmp_dir: dir} do
    # Boot kv plugin so `<plugin>.sark.db` exists for session writes.
    if pid = Process.whereis(AuthRegistry) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 5_000)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (1_000 -> :ok)
    end

    start_supervised!({AuthRegistry, %{}})

    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    {private, public_map, _kid} = JWTFixture.keypair()
    jwks = JWTFixture.jwks(public_map)

    idp = %Sark.Config.IdP{
      issuer: @issuer,
      audience: @client_id,
      client_id: @client_id,
      client_secret: @client_secret
    }

    {:ok, _} = start_supervised(Sark.OAuth.Correlator)

    prior_idp = Application.get_env(:sark, :idp)
    prior_plug = Application.get_env(:sark, :req_plug)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :req_plug, {Req.Test, :sark_idp})

    {:ok, ks} = start_supervised({Sark.Auth.KeyStore, idp})

    captured_token_body = :ets.new(:captured_token_body, [:set, :public])

    Req.Test.stub(:sark_idp, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "authorization_endpoint" => @authorize_endpoint,
            "token_endpoint" => @token_endpoint,
            "jwks_uri" => @jwks_uri
          })

        "/jwks" ->
          Req.Test.json(conn, jwks)

        "/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)
          :ets.insert(captured_token_body, {:last, form})

          id_token =
            JWTFixture.sign(private, %{
              "iss" => @issuer,
              "aud" => @client_id,
              "sub" => "117xxx",
              "email" => "ryan@example.com",
              "name" => "Ryan",
              "exp" => System.system_time(:second) + 3600
            })

          Req.Test.json(conn, %{
            "access_token" => "ya29.opaque",
            "id_token" => id_token,
            "refresh_token" => "1//refresh-abc",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
      end
    end)

    Req.Test.allow(:sark_idp, self(), ks)

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :req_plug, prior_plug)
    end)

    {:ok, captured: captured_token_body, signer: JWTFixture.signer(private)}
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp captured_form(captured) do
    case :ets.lookup(captured, :last) do
      [{_, form}] -> form
      [] -> %{}
    end
  end

  # PKCE helpers
  defp gen_verifier do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp challenge_for(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp do_authorize(challenge, resource) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => "http://localhost:7777/callback",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "abc",
        "resource" => resource
      })

    call(conn(:get, "/oauth/authorize?" <> query))
  end

  defp do_token(verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => "auth-code-xyz",
        "redirect_uri" => "http://localhost:7777/callback",
        "code_verifier" => verifier,
        "client_id" => @client_id
      })

    conn(:post, "/oauth/token", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> call()
  end

  describe "/oauth/authorize" do
    test "302s to upstream, stashes plugin correlation by code_challenge" do
      verifier = gen_verifier()
      challenge = challenge_for(verifier)

      conn = do_authorize(challenge, "http://localhost:8080/kv/mcp")
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ @authorize_endpoint
      assert {:ok, "kv"} = Sark.OAuth.Correlator.lookup(verifier)
    end

    test "injects default scope when client omits it" do
      verifier = gen_verifier()
      challenge = challenge_for(verifier)
      conn = do_authorize(challenge, "http://localhost:8080/kv/mcp")
      [location] = get_resp_header(conn, "location")
      params = URI.decode_query(URI.parse(location).query)
      assert params["scope"] == "openid email profile"
    end
  end

  describe "/oauth/token" do
    test "forwards code, injects client_secret, returns a sark session token", ctx do
      verifier = gen_verifier()
      challenge = challenge_for(verifier)

      _ = do_authorize(challenge, "http://localhost:8080/kv/mcp")
      conn = do_token(verifier)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert "sk-sark-" <> _ = body["access_token"]
      assert body["token_type"] == "Bearer"
      # Decoupled from upstream's 1h: sark session token is long-lived,
      # JIT-refreshes upstream internally.
      assert body["expires_in"] >= 24 * 3600

      # Upstream got our client_secret + the original code.
      forwarded = captured_form(ctx.captured)
      assert forwarded["client_id"] == @client_id
      assert forwarded["client_secret"] == @client_secret
      assert forwarded["code"] == "auth-code-xyz"
      assert forwarded["code_verifier"] == verifier

      # Session row landed in kv.sark.db.
      assert {:ok, %{"claims" => claims, "upstream_refresh" => "1//refresh-abc"}} =
               Sark.Auth.Session.lookup("kv", body["access_token"])

      assert claims["sub"] == "117xxx"
      assert claims["email"] == "ryan@example.com"
    end

    test "fails cleanly when no correlation was stashed (no prior /authorize)" do
      verifier = gen_verifier()
      conn = do_token(verifier)

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "token_failed"
    end

    test "session token then works as a bearer through AuthPlug" do
      verifier = gen_verifier()
      challenge = challenge_for(verifier)
      _ = do_authorize(challenge, "http://localhost:8080/kv/mcp")
      conn = do_token(verifier)
      session_token = Jason.decode!(conn.resp_body)["access_token"]

      # Drive AuthPlug directly to assert the session token resolves to
      # the right envelope. (Going through full Endpoint would also hit
      # Phantom's MCP request handler which expects a real MCP body —
      # not what we're testing here.)
      auth_conn =
        conn(:post, "/kv/mcp")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{session_token}")
        |> Sark.AuthPlug.call(Sark.AuthPlug.init([]))

      refute auth_conn.halted
      assert auth_conn.assigns.plugin == "kv"

      decoded = Jason.decode!(auth_conn.assigns.sark_auth)
      assert decoded["sub"] == "117xxx"
    end
  end
end

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
      client_secret: @client_secret,
      rules: [%{match: nil, plugins: :all}]
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

          :ets.insert(
            captured_token_body,
            {:auth, Plug.Conn.get_req_header(conn, "authorization")}
          )

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

  defp captured_auth(captured) do
    case :ets.lookup(captured, :auth) do
      [{_, header}] -> header
      [] -> []
    end
  end

  # PKCE helpers
  defp gen_verifier do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp challenge_for(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  @client_redirect "http://localhost:7777/callback"
  @client_state "client-state-abc"
  # Plug.Test conn defaults to host www.example.com; :sark :url is unset
  # in this suite, so Sark.URL.base derives the callback from the conn.
  @sark_callback "http://www.example.com/oauth/callback"

  defp do_authorize(challenge, resource, opts \\ []) do
    query =
      %{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => Keyword.get(opts, :redirect_uri, @client_redirect),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => @client_state,
        "resource" => resource
      }
      |> Map.merge(Keyword.get(opts, :extra, %{}))
      |> Map.drop(Keyword.get(opts, :drop, []))
      |> URI.encode_query()

    call(conn(:get, "/oauth/authorize?" <> query))
  end

  defp do_callback(query_map) do
    call(conn(:get, "/oauth/callback?" <> URI.encode_query(query_map)))
  end

  defp do_token(sark_code, verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => sark_code,
        "redirect_uri" => @client_redirect,
        "code_verifier" => verifier,
        "client_id" => @client_id
      })

    conn(:post, "/oauth/token", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> call()
  end

  defp location_query(conn) do
    [location] = get_resp_header(conn, "location")
    {location, URI.decode_query(URI.parse(location).query)}
  end

  # Drive the full broker dance up to (but not including) the token call.
  # Returns the client's PKCE verifier + the sark-issued downstream code.
  defp run_to_code(
         resource \\ "http://localhost:8080/kv/mcp",
         upstream_code \\ "upstream-code-xyz"
       ) do
    verifier = gen_verifier()
    auth_conn = do_authorize(challenge_for(verifier), resource)
    {_, up_params} = location_query(auth_conn)

    cb_conn = do_callback(%{"code" => upstream_code, "state" => up_params["state"]})
    {_, client_params} = location_query(cb_conn)

    {verifier, client_params["code"]}
  end

  describe "/oauth/authorize" do
    test "302s to upstream with sark's own callback + opaque state, not the client's" do
      conn = do_authorize(challenge_for(gen_verifier()), "http://localhost:8080/kv/mcp")

      assert conn.status == 302
      {location, params} = location_query(conn)
      assert location =~ @authorize_endpoint

      # Sark substitutes its own fixed redirect + opaque state.
      assert params["redirect_uri"] == @sark_callback
      assert params["state"] != @client_state
      assert is_binary(params["state"]) and params["state"] != ""
      assert params["client_id"] == @client_id

      # Downstream PKCE challenge stays downstream — never forwarded.
      refute Map.has_key?(params, "code_challenge")
    end

    test "injects default scope when client omits it" do
      conn = do_authorize(challenge_for(gen_verifier()), "http://localhost:8080/kv/mcp")
      {_, params} = location_query(conn)
      assert params["scope"] == "openid email profile"
    end

    test "rejects a non-loopback http redirect_uri" do
      conn =
        do_authorize(challenge_for(gen_verifier()), "http://localhost:8080/kv/mcp",
          redirect_uri: "http://evil.example.com/callback"
        )

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "authorize_failed"
    end

    test "requires a PKCE challenge" do
      conn =
        do_authorize("ignored", "http://localhost:8080/kv/mcp", drop: ["code_challenge"])

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "authorize_failed"
    end

    test "missing resource on the global endpoint fails cleanly" do
      conn = do_authorize(challenge_for(gen_verifier()), "", drop: ["resource"])
      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "authorize_failed"
    end
  end

  describe "/:plugin/oauth/authorize (path-derived plugin, no resource)" do
    test "302s to upstream using the plugin from the path, resource absent" do
      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => @client_id,
          "redirect_uri" => @client_redirect,
          "code_challenge" => challenge_for(gen_verifier()),
          "code_challenge_method" => "S256",
          "state" => @client_state
        })

      conn = call(conn(:get, "/kv/oauth/authorize?" <> query))

      assert conn.status == 302
      {location, params} = location_query(conn)
      assert location =~ @authorize_endpoint
      assert params["redirect_uri"] == @sark_callback
      assert params["state"] != @client_state

      # And the bridged session lands in the kv plugin's DB — proving the
      # path plugin threaded through stash → callback → token.
      {_, up_params} = location_query(conn)
      cb = do_callback(%{"code" => "upstream-code-xyz", "state" => up_params["state"]})
      {_, client_params} = location_query(cb)
      assert client_params["code"] != nil
    end
  end

  describe "/oauth/callback" do
    test "bridges a sark code back to the client's redirect_uri with original state" do
      verifier = gen_verifier()
      auth_conn = do_authorize(challenge_for(verifier), "http://localhost:8080/kv/mcp")
      {_, up_params} = location_query(auth_conn)

      conn = do_callback(%{"code" => "upstream-code-xyz", "state" => up_params["state"]})

      assert conn.status == 302
      {location, params} = location_query(conn)
      assert String.starts_with?(location, @client_redirect)
      assert params["state"] == @client_state
      # A freshly-minted sark code, not the upstream one.
      assert is_binary(params["code"]) and params["code"] != ""
      assert params["code"] != "upstream-code-xyz"
    end

    test "bridges an upstream error back to the client" do
      auth_conn = do_authorize(challenge_for(gen_verifier()), "http://localhost:8080/kv/mcp")
      {_, up_params} = location_query(auth_conn)

      conn = do_callback(%{"error" => "access_denied", "state" => up_params["state"]})

      assert conn.status == 302
      {location, params} = location_query(conn)
      assert String.starts_with?(location, @client_redirect)
      assert params["error"] == "access_denied"
      assert params["state"] == @client_state
    end

    test "rejects unknown / expired state" do
      conn = do_callback(%{"code" => "x", "state" => "never-stashed"})
      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "callback_failed"
    end

    test "state is single-use" do
      auth_conn = do_authorize(challenge_for(gen_verifier()), "http://localhost:8080/kv/mcp")
      {_, up_params} = location_query(auth_conn)

      assert do_callback(%{"code" => "c", "state" => up_params["state"]}).status == 302
      assert do_callback(%{"code" => "c", "state" => up_params["state"]}).status == 502
    end
  end

  describe "/oauth/token" do
    test "verifies PKCE, swaps to the upstream code, injects secret, mints a session", ctx do
      {verifier, sark_code} = run_to_code()
      conn = do_token(sark_code, verifier)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert "sk-sark-" <> _ = body["access_token"]
      assert body["token_type"] == "Bearer"
      # Decoupled from upstream's 1h: sark session token is long-lived,
      # JIT-refreshes upstream internally.
      assert body["expires_in"] >= 24 * 3600

      # Upstream got the UPSTREAM code (not sark's), sark's own callback
      # redirect, and never the client's verifier. Client credentials go
      # via HTTP Basic, not the form body.
      forwarded = captured_form(ctx.captured)
      assert forwarded["code"] == "upstream-code-xyz"
      assert forwarded["redirect_uri"] == @sark_callback
      refute Map.has_key?(forwarded, "code_verifier")
      refute Map.has_key?(forwarded, "client_secret")

      assert captured_auth(ctx.captured) == [
               "Basic " <> Base.encode64("#{@client_id}:#{@client_secret}")
             ]

      # Session row landed in kv.sark.db.
      assert {:ok, %{"claims" => claims, "upstream_refresh" => "1//refresh-abc"}} =
               Sark.Auth.Session.lookup("kv", body["access_token"])

      assert claims["sub"] == "117xxx"
      assert claims["email"] == "ryan@example.com"
    end

    test "rejects a bad PKCE verifier" do
      {_verifier, sark_code} = run_to_code()
      conn = do_token(sark_code, gen_verifier())

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "token_failed"
    end

    test "rejects an unknown / expired code" do
      conn = do_token("never-issued", gen_verifier())
      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "token_failed"
    end

    test "sark code is single-use" do
      {verifier, sark_code} = run_to_code()
      assert do_token(sark_code, verifier).status == 200
      assert do_token(sark_code, verifier).status == 502
    end

    test "session token then works as a bearer through AuthPlug" do
      {verifier, sark_code} = run_to_code()
      conn = do_token(sark_code, verifier)
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

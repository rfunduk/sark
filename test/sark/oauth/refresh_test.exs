defmodule Sark.OAuth.RefreshTest do
  use ExUnit.Case, async: false

  alias Sark.Auth.Session
  alias Sark.MCP.Registration
  alias Sark.MCP.Registry, as: SarkRegistry
  alias Sark.OAuth.Refresh
  alias Sark.Plugin
  alias Sark.Plugin.Loader
  alias Sark.Test.JWTFixture

  @moduletag :tmp_dir

  @kv_fixture Path.expand("../../fixtures/plugins/kv", __DIR__)
  @issuer "https://idp.example.com"
  @token_endpoint "https://idp.example.com/token"
  @jwks_uri "https://idp.example.com/jwks"
  @client_id "test-client-id"
  @client_secret "test-client-secret"

  setup %{tmp_dir: dir} do
    SarkRegistry.ensure_table()
    SarkRegistry.delete_plugin("kv")

    router = Registration.router_module("kv")
    :persistent_term.put({Phantom, router, :tools}, [])
    :persistent_term.put({Phantom, router, :initialized}, false)

    spec = Loader.load!("kv", @kv_fixture)
    start_supervised!({Plugin, spec: spec, data_dir: dir})

    {private, public_map, _kid} = JWTFixture.keypair()

    idp = %Sark.Config.IdP{
      issuer: @issuer,
      audience: @client_id,
      client_id: @client_id,
      client_secret: @client_secret
    }

    upstream_behavior = :ets.new(:upstream_behavior, [:set, :public])
    :ets.insert(upstream_behavior, {:mode, :ok})

    captured_form = :ets.new(:captured_form, [:set, :public])

    Req.Test.stub(:idp_refresh, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "token_endpoint" => @token_endpoint,
            "jwks_uri" => @jwks_uri
          })

        "/jwks" ->
          Req.Test.json(conn, JWTFixture.jwks(public_map))

        "/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(captured_form, {:last, URI.decode_query(body)})
          :ets.update_counter(captured_form, :calls, 1, {:calls, 0})

          :ets.insert(
            captured_form,
            {:auth_header, Plug.Conn.get_req_header(conn, "authorization")}
          )

          case :ets.lookup(upstream_behavior, :mode) do
            [{:mode, :revoked}] ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                400,
                Jason.encode!(%{"error" => "invalid_grant"})
              )

            [{:mode, :network_500}] ->
              Plug.Conn.send_resp(conn, 500, "boom")

            _ ->
              # Google-style refresh response: access_token + expires_in,
              # NO id_token, NO refresh_token reissue.
              Req.Test.json(conn, %{
                "access_token" => "ya29.new-opaque",
                "expires_in" => 3600,
                "token_type" => "Bearer"
              })
          end
      end
    end)

    prior_idp = Application.get_env(:sark, :idp)
    prior_plug = Application.get_env(:sark, :req_plug)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :req_plug, {Req.Test, :idp_refresh})

    {:ok, ks} = start_supervised({Sark.Auth.KeyStore, idp})
    Req.Test.allow(:idp_refresh, self(), ks)

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :req_plug, prior_plug)
    end)

    {:ok,
     idp: idp,
     private: private,
     upstream_behavior: upstream_behavior,
     captured_form: captured_form}
  end

  defp seed_session(plugin, opts) do
    claims = Keyword.get(opts, :claims, %{"sub" => "117xxx", "email" => "ryan@example.com"})
    refresh = Keyword.get(opts, :upstream_refresh, "1//refresh-abc")
    expires_in_sec = Keyword.get(opts, :expires_in_sec, 3600)
    expires_at = DateTime.utc_now() |> DateTime.add(expires_in_sec, :second)
    {:ok, token} = Session.create(plugin, claims, refresh, expires_at)
    {:ok, row} = Session.lookup(plugin, token)
    {token, row}
  end

  test "fresh session needs no upstream call", ctx do
    {_token, row} = seed_session("kv", expires_in_sec: 3600)

    assert {:ok, returned} = Refresh.maybe_refresh("kv", row, ctx.idp)
    assert returned == row
    assert :ets.lookup(ctx.captured_form, :last) == []
  end

  test "near-expiry session triggers refresh, row updated, claims preserved", ctx do
    {token, row} = seed_session("kv", expires_in_sec: 60)

    assert {:ok, refreshed} = Refresh.maybe_refresh("kv", row, ctx.idp)
    assert refreshed["claims"]["sub"] == "117xxx"

    [{:last, form}] = :ets.lookup(ctx.captured_form, :last)
    assert form["grant_type"] == "refresh_token"
    assert form["refresh_token"] == "1//refresh-abc"

    # client_secret_basic — secret rides the Authorization header, never
    # the form body (Okta apps configured for Basic 401 on form secrets).
    refute Map.has_key?(form, "client_secret")
    expected = "Basic " <> Base.encode64(@client_id <> ":" <> @client_secret)
    assert [{:auth_header, [^expected]}] = :ets.lookup(ctx.captured_form, :auth_header)

    {:ok, persisted} = Session.lookup("kv", token)

    assert_new_expiry_is_in_future(persisted["expires_at"])
  end

  test "revoked refresh_token drops the session and returns :revoked", ctx do
    :ets.insert(ctx.upstream_behavior, {:mode, :revoked})
    {token, row} = seed_session("kv", expires_in_sec: 60)

    assert {:error, :revoked} = Refresh.maybe_refresh("kv", row, ctx.idp)
    assert :not_found = Session.lookup("kv", token)
  end

  test "transient upstream error preserves the session", ctx do
    :ets.insert(ctx.upstream_behavior, {:mode, :network_500})
    {token, row} = seed_session("kv", expires_in_sec: 60)

    assert {:error, _} = Refresh.maybe_refresh("kv", row, ctx.idp)
    assert {:ok, _row_still_there} = Session.lookup("kv", token)
  end

  test "concurrent requests near expiry hit upstream exactly once", ctx do
    {_token, row} = seed_session("kv", expires_in_sec: 60)

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Refresh.maybe_refresh("kv", row, ctx.idp) end) end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [{:calls, 1}] = :ets.lookup(ctx.captured_form, :calls)
  end

  test "session w/ null upstream_refresh does not attempt refresh", ctx do
    {_token, row} = seed_session("kv", upstream_refresh: nil, expires_in_sec: 60)

    assert {:error, :no_refresh_token} = Refresh.maybe_refresh("kv", row, ctx.idp)
    assert :ets.lookup(ctx.captured_form, :last) == []
  end

  defp assert_new_expiry_is_in_future(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    assert DateTime.diff(dt, DateTime.utc_now(), :second) > 1500
  end
end

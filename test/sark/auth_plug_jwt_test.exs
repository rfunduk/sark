defmodule Sark.AuthPlug.JWTTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias Sark.AuthPlug
  alias Sark.AuthRegistry
  alias Sark.Test.JWTFixture

  @issuer "https://idp.example.com"
  @audience "sark-test"
  @jwks_uri "https://idp.example.com/jwks"

  setup do
    {private, public_map, _kid} = JWTFixture.keypair()
    jwks_doc = JWTFixture.jwks(public_map)

    idp = %Sark.Config.IdP{
      issuer: @issuer,
      audience: @audience
    }

    Req.Test.stub(:sark_idp, fn conn ->
      case conn.request_path do
        "/jwks" ->
          Req.Test.json(conn, jwks_doc)

        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{"issuer" => @issuer, "jwks_uri" => @jwks_uri})
      end
    end)

    prior_idp = Application.get_env(:sark, :idp)
    prior_plug = Application.get_env(:sark, :req_plug)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :req_plug, {Req.Test, :sark_idp})

    # AuthRegistry reset (parallel-safe via async: false above).
    if pid = Process.whereis(AuthRegistry) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 5_000)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (1_000 -> :ok)
    end

    start_supervised!({AuthRegistry, %{"sk-bearer" => %{name: "fallback", allowed: :all}}})
    {:ok, ks} = start_supervised({Sark.Auth.KeyStore, idp})
    Req.Test.allow(:sark_idp, self(), ks)

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :req_plug, prior_plug)
    end)

    {:ok, signer: JWTFixture.signer(private)}
  end

  defp call(conn), do: AuthPlug.call(conn, AuthPlug.init([]))

  defp bearer(token) do
    conn(:post, "/kv/mcp")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp jwt_claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "117xxx",
        "email" => "ryan@example.com",
        "name" => "Ryan",
        "exp" => now + 600,
        "iat" => now
      },
      overrides
    )
  end

  test "valid JWT lets the request through with claims as the sark_auth envelope", ctx do
    token = JWTFixture.sign_with_kid(jwt_claims(), ctx.signer)
    conn = call(bearer(token))

    refute conn.halted
    assert conn.assigns.plugin == "kv"
    assert conn.assigns.token_name == "ryan@example.com"

    decoded = Jason.decode!(conn.assigns.sark_auth)
    assert decoded["iss"] == @issuer
    assert decoded["aud"] == @audience
    assert decoded["sub"] == "117xxx"
    assert decoded["email"] == "ryan@example.com"
  end

  test "expired JWT → 401 with challenge", ctx do
    now = System.system_time(:second)
    token = JWTFixture.sign_with_kid(jwt_claims(%{"exp" => now - 60}), ctx.signer)

    conn = call(bearer(token))
    assert conn.status == 401
    assert [_challenge] = get_resp_header(conn, "www-authenticate")
  end

  test "wrong audience → 401", ctx do
    token = JWTFixture.sign_with_kid(jwt_claims(%{"aud" => "someone-else"}), ctx.signer)
    conn = call(bearer(token))
    assert conn.status == 401
  end

  test "wrong issuer → 401", ctx do
    token =
      JWTFixture.sign_with_kid(jwt_claims(%{"iss" => "https://evil.example.com"}), ctx.signer)

    conn = call(bearer(token))
    assert conn.status == 401
  end

  test "bad signature → 401" do
    {other_private, _public, _kid} = JWTFixture.keypair()
    other_signer = JWTFixture.signer(other_private)
    token = JWTFixture.sign_with_kid(jwt_claims(), other_signer)

    conn = call(bearer(token))
    assert conn.status == 401
  end

  test "bearer token still works alongside JWT mode" do
    conn = call(bearer("sk-bearer"))
    refute conn.halted
    assert conn.assigns.token_name == "fallback"
    decoded = Jason.decode!(conn.assigns.sark_auth)
    assert decoded["iss"] == "sark.bearer"
  end

  test "non-JWT garbage falls through and gets unauthorized at bearer step" do
    conn = call(bearer("not.a.jwt"))
    assert conn.status == 401
  end

  test "JWT audience as a list including ours is accepted", ctx do
    token =
      JWTFixture.sign_with_kid(
        jwt_claims(%{"aud" => ["some-other", @audience]}),
        ctx.signer
      )

    conn = call(bearer(token))
    refute conn.halted
    assert conn.assigns.plugin == "kv"
  end
end

defmodule Sark.OAuth.BrokerTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Sark.Endpoint

  @issuer "https://idp.example.com"
  @authorize_endpoint "https://idp.example.com/authorize"
  @token_endpoint "https://idp.example.com/token"
  @jwks_uri "https://idp.example.com/jwks"
  @client_id "test-client-id"
  @client_secret "test-client-secret"

  setup do
    idp = %Sark.Config.IdP{
      issuer: @issuer,
      audience: @client_id,
      client_id: @client_id,
      client_secret: @client_secret
    }

    Req.Test.stub(:sark_idp, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "authorization_endpoint" => @authorize_endpoint,
            "token_endpoint" => @token_endpoint,
            "jwks_uri" => @jwks_uri
          })

        "/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          # Echo the form body back as JSON so tests can assert on what
          # sark forwarded upstream.
          form = URI.decode_query(body)
          Req.Test.json(conn, %{"upstream_received" => form})

        "/jwks" ->
          Req.Test.json(conn, %{"keys" => []})
      end
    end)

    prior_idp = Application.get_env(:sark, :idp)
    prior_plug = Application.get_env(:sark, :req_plug)
    Application.put_env(:sark, :idp, idp)
    Application.put_env(:sark, :req_plug, {Req.Test, :sark_idp})

    {:ok, ks} = start_supervised({Sark.Auth.KeyStore, idp})
    Req.Test.allow(:sark_idp, self(), ks)

    on_exit(fn ->
      Application.put_env(:sark, :idp, prior_idp)
      Application.put_env(:sark, :req_plug, prior_plug)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  describe "/oauth/authorize" do
    test "302s to upstream w/ passthrough params" do
      query = [
        response_type: "code",
        client_id: @client_id,
        redirect_uri: "http://localhost:7777/callback",
        code_challenge: "abc",
        code_challenge_method: "S256",
        state: "xyz"
      ]

      conn = call(conn(:get, "/oauth/authorize?" <> URI.encode_query(query)))

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      uri = URI.parse(location)
      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == @authorize_endpoint

      params = URI.decode_query(uri.query)
      assert params["response_type"] == "code"
      assert params["client_id"] == @client_id
      assert params["redirect_uri"] == "http://localhost:7777/callback"
      assert params["code_challenge"] == "abc"
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "xyz"
    end

    test "injects default scope when client omits it" do
      conn = call(conn(:get, "/oauth/authorize?response_type=code&client_id=#{@client_id}"))

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      params = URI.decode_query(URI.parse(location).query)
      assert params["scope"] == "openid email profile"
    end

    test "honors client-supplied scope" do
      conn =
        call(
          conn(
            :get,
            "/oauth/authorize?response_type=code&client_id=#{@client_id}&scope=openid"
          )
        )

      [location] = get_resp_header(conn, "location")
      params = URI.decode_query(URI.parse(location).query)
      assert params["scope"] == "openid"
    end
  end

  describe "/oauth/token" do
    test "proxies POST to upstream and injects client_secret" do
      body =
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => "auth-code-xyz",
          "redirect_uri" => "http://localhost:7777/callback",
          "code_verifier" => "the-verifier",
          "client_id" => @client_id
        })

      conn =
        conn(:post, "/oauth/token", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      assert conn.status == 200

      decoded = Jason.decode!(conn.resp_body)
      forwarded = decoded["upstream_received"]

      assert forwarded["grant_type"] == "authorization_code"
      assert forwarded["code"] == "auth-code-xyz"
      assert forwarded["code_verifier"] == "the-verifier"
      assert forwarded["client_id"] == @client_id
      assert forwarded["client_secret"] == @client_secret
    end

    test "swaps Google-style opaque access_token for id_token in the response" do
      # Re-stub /token to return Google-shaped response: opaque access +
      # JWT-shaped id_token.
      Req.Test.stub(:sark_idp, fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{
              "issuer" => @issuer,
              "authorization_endpoint" => @authorize_endpoint,
              "token_endpoint" => @token_endpoint,
              "jwks_uri" => @jwks_uri
            })

          "/token" ->
            Req.Test.json(conn, %{
              "access_token" => "ya29.opaque-google-token",
              "id_token" => "header.payload.sig",
              "token_type" => "Bearer",
              "expires_in" => 3600
            })

          "/jwks" ->
            Req.Test.json(conn, %{"keys" => []})
        end
      end)

      Req.Test.allow(:sark_idp, self(), Process.whereis(Sark.Auth.KeyStore))

      body = URI.encode_query(%{"grant_type" => "authorization_code", "code" => "c"})

      conn =
        conn(:post, "/oauth/token", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["access_token"] == "header.payload.sig"
      assert decoded["id_token"] == "header.payload.sig"
    end

    test "leaves JWT-shaped access_token unchanged (Okta/Auth0 path)" do
      Req.Test.stub(:sark_idp, fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{
              "issuer" => @issuer,
              "authorization_endpoint" => @authorize_endpoint,
              "token_endpoint" => @token_endpoint,
              "jwks_uri" => @jwks_uri
            })

          "/token" ->
            Req.Test.json(conn, %{
              "access_token" => "header.payload.sig",
              "id_token" => "different.id.token",
              "token_type" => "Bearer"
            })

          "/jwks" ->
            Req.Test.json(conn, %{"keys" => []})
        end
      end)

      Req.Test.allow(:sark_idp, self(), Process.whereis(Sark.Auth.KeyStore))

      body = URI.encode_query(%{"grant_type" => "authorization_code", "code" => "c"})

      conn =
        conn(:post, "/oauth/token", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["access_token"] == "header.payload.sig"
    end

    test "overrides any client-supplied client_secret with the configured one" do
      body =
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => "c",
          "client_secret" => "client-tried-to-set-this"
        })

      conn =
        conn(:post, "/oauth/token", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["upstream_received"]["client_secret"] == @client_secret
    end
  end
end

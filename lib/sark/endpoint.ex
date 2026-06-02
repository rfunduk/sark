defmodule Sark.Endpoint do
  @moduledoc """
  HTTP entrypoint.

    * `/health` — unauthenticated liveness
    * `/<plugin>/.well-known/oauth-protected-resource` — RFC 9728
      protected-resource metadata. Unauthenticated. Tells MCP clients
      where to find this resource's auth servers (sark itself, in
      broker mode).
    * `/.well-known/oauth-authorization-server` — RFC 8414 auth-server
      metadata. Unauthenticated. Advertises sark's `/oauth/authorize`
      + `/oauth/token`.
    * `/oauth/authorize` — broker. Stashes the client's redirect_uri +
      PKCE challenge, 302s to upstream IdP's authorize endpoint with
      sark's *own* fixed `/oauth/callback` redirect + opaque state.
    * `/oauth/callback` — broker. Upstream redirects here (one fixed URI
      the operator registers); sark bridges a freshly-minted code back
      to the client's original (ephemeral localhost) redirect_uri.
    * `/oauth/token` — broker. Verifies the client's PKCE, swaps the
      sark code for the upstream code, proxies POST to upstream token
      endpoint w/ client_secret injected from config.
    * `/oauth/register` — RFC 7591 DCR stub. Unauthenticated. Stateless;
      returns the single pre-configured `auth.idp.client_id` to every
      caller (sark is one shared upstream client). Exists only because
      spec-strict MCP clients (Claude Code) refuse auth servers lacking
      a `registration_endpoint`.
    * `/<plugin>/mcp` — per-plugin MCP server (one Phantom router per
      plugin, looked up at request time so hot-reloaded plugins don't
      need an endpoint restart)

  All non-health, non-well-known, non-broker routes pass through
  `Sark.AuthPlug`. By the time we get to dispatch the conn already has
  `:plugin` assigned.
  """

  use Plug.Router

  alias Sark.MCP.Registration

  plug(Sark.AuthPlug)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [{:urlencoded, length: 1_000_000}, {:json, length: 1_000_000}],
    pass: ["application/json", "application/x-www-form-urlencoded"],
    json_decoder: Jason
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/:plugin/.well-known/oauth-protected-resource" do
    serve_protected_resource_metadata(conn, plugin)
  end

  get "/.well-known/oauth-authorization-server" do
    serve_authorization_server_metadata(conn)
  end

  get "/oauth/authorize" do
    Sark.OAuth.Broker.authorize(conn)
  end

  get "/oauth/callback" do
    Sark.OAuth.Broker.callback(conn)
  end

  post "/oauth/token" do
    Sark.OAuth.Broker.token(conn)
  end

  post "/oauth/register" do
    Sark.OAuth.Broker.register(conn)
  end

  match "/:plugin/mcp" do
    dispatch_to_plugin(conn, plugin)
  end

  match "/:plugin/mcp/*_rest" do
    dispatch_to_plugin(conn, plugin)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp dispatch_to_plugin(conn, plugin) do
    router = Registration.router_module(plugin)

    if Code.ensure_loaded?(router) do
      opts = Phantom.Plug.init(router: router, origins: :all, validate_origin: false)
      Phantom.Plug.call(conn, opts)
    else
      send_resp(conn, 404, "not found")
    end
  end

  # RFC 9728 protected-resource metadata. Advertises sark itself as the
  # authorization server when broker mode is active (`auth.idp:` set).
  # Clients hit sark's `/oauth/*` endpoints; sark proxies upstream.
  defp serve_protected_resource_metadata(conn, plugin) do
    router = Registration.router_module(plugin)

    if Code.ensure_loaded?(router) do
      body = Jason.encode!(metadata_doc(conn, plugin))

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp metadata_doc(conn, plugin) do
    base = %{"resource" => resource_url(conn, plugin)}

    case Application.get_env(:sark, :idp) do
      %Sark.Config.IdP{} ->
        Map.merge(base, %{
          "authorization_servers" => [Sark.URL.base(conn)],
          "bearer_methods_supported" => ["header", "query"],
          "scopes_supported" => ["openid", "email", "profile"]
        })

      _ ->
        base
    end
  end

  # RFC 8414 authorization-server metadata. Advertises sark's broker
  # endpoints (sark IS the auth server, from the client's perspective).
  defp serve_authorization_server_metadata(conn) do
    case Application.get_env(:sark, :idp) do
      %Sark.Config.IdP{issuer: issuer} ->
        base = Sark.URL.base(conn)

        body =
          Jason.encode!(%{
            "issuer" => issuer,
            "authorization_endpoint" => "#{base}/oauth/authorize",
            "token_endpoint" => "#{base}/oauth/token",
            "registration_endpoint" => "#{base}/oauth/register",
            "response_types_supported" => ["code"],
            "grant_types_supported" => ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported" => ["S256"],
            "scopes_supported" => ["openid", "email", "profile"],
            "token_endpoint_auth_methods_supported" => ["none", "client_secret_post"]
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp resource_url(conn, plugin), do: "#{Sark.URL.base(conn)}/#{plugin}/mcp"
end

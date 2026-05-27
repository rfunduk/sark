defmodule Sark.Endpoint do
  @moduledoc """
  HTTP entrypoint.

    * `/health` — unauthenticated liveness
    * `/<plugin>/.well-known/oauth-protected-resource` — RFC 9728
      protected-resource metadata. Unauthenticated. Tells MCP clients
      where to find this resource's auth servers. Pre-Phase-2 the
      `authorization_servers` field is absent — bearer-only deployment.
    * `/<plugin>/mcp` — per-plugin MCP server (one Phantom router per
      plugin, looked up at request time so hot-reloaded plugins don't
      need an endpoint restart)

  All non-health, non-well-known routes pass through `Sark.AuthPlug`,
  which both bearer-checks and scopes the token to the URL's plugin. By
  the time we get to dispatch the conn already has `:plugin` assigned.
  """

  use Plug.Router

  alias Sark.MCP.Registration

  plug(Sark.AuthPlug)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/:plugin/.well-known/oauth-protected-resource" do
    serve_protected_resource_metadata(conn, plugin)
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

  # RFC 9728 protected-resource metadata. Always returns the `resource`
  # field. When `auth.idp:` is configured, also advertises
  # `authorization_servers` (the IdP issuer) and `bearer_methods_supported`.
  # Bearer-only deployments (no IdP) omit those — the client falls back
  # to whatever bearer-issuance flow the operator documents.
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
      %Sark.Config.IdP{issuer: issuer} ->
        Map.merge(base, %{
          "authorization_servers" => [issuer],
          "bearer_methods_supported" => ["header", "query"]
        })

      _ ->
        base
    end
  end

  defp resource_url(conn, plugin), do: "#{Sark.URL.base(conn)}/#{plugin}/mcp"
end

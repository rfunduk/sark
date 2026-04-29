defmodule Sark.Endpoint do
  @moduledoc """
  HTTP entrypoint.

    * `/health` — unauthenticated liveness
    * `/<plugin>/mcp` — per-plugin MCP server (one Phantom router per
      plugin, looked up at request time so hot-reloaded plugins don't
      need an endpoint restart)

  All non-health routes pass through `Sark.AuthPlug`, which both
  bearer-checks and scopes the token to the URL's plugin. By the time
  we get to dispatch the conn already has `:plugin` assigned.
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
end

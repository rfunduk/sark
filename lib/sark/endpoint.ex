defmodule Sark.Endpoint do
  @moduledoc """
  HTTP entrypoint. `/health` for liveness, `/mcp` forwarded to Phantom
  for the MCP protocol. All non-health routes pass through `Sark.AuthPlug`.
  """

  use Plug.Router

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

  forward("/mcp",
    to: Phantom.Plug,
    init_opts: [
      router: Sark.MCP.Router,
      origins: :all,
      validate_origin: false
    ]
  )

  match _ do
    send_resp(conn, 404, "not found")
  end
end

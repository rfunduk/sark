defmodule Sark.MCP.Router do
  @moduledoc """
  Sark's MCP router. Phantom-style router; each tool/prompt/resource is
  declared with the corresponding macro and the handler function lives
  in this module (or a referenced handler module).

  M1 ships a single smoke-test tool, `ping`. Real plugin-driven tools
  land in M3 once the plugin loader exists.
  """

  use Phantom.Router,
    name: "sark",
    vsn: "0.1.0",
    instructions: @moduledoc

  require Phantom.Tool, as: Tool

  tool :ping,
    description: "Smoke-test tool. Echoes the given message back, prefixed with 'pong: '." do
    field(:message, :string, required: true, description: "Text to echo back.")
  end

  def ping(%{"message" => msg}, session) do
    {:reply, Tool.text("pong: #{msg}"), session}
  end

  @impl true
  def connect(session, _info) do
    # Bearer auth already validated upstream by Sark.AuthPlug — `:token_name`
    # is on conn.assigns and could be threaded into session here once we
    # need per-token authorization.
    {:ok, session}
  end
end

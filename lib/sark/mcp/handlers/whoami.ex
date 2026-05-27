defmodule Sark.MCP.Handlers.Whoami do
  @moduledoc """
  Returns the caller's `:sark_auth` envelope verbatim. Useful for:

    * Inspecting JWT claim shape before writing `auth.idp.rules:` (claim
      paths differ wildly across IdPs).
    * Sanity-checking that bearer / OAuth identity actually flowed in.
    * Plugin authors debugging their `json_extract(:sark_auth, ...)`
      expressions.
  """

  alias Phantom.Tool, as: Reply

  alias Sark.MCP.Telemetry

  @spec call(String.t(), map, term, keyword) :: {:reply, map, term}
  def call(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_whoami", params, fn ->
      do_call(session, opts)
    end)
  end

  defp do_call(session, opts) do
    envelope = resolve(session, opts)

    case envelope do
      nil ->
        {:reply, Reply.error("no caller identity (sark_auth missing)"), session}

      bin when is_binary(bin) ->
        # Re-decode + pretty-print so the agent gets structured JSON
        # rather than a JSON-encoded string blob.
        case Jason.decode(bin) do
          {:ok, decoded} -> {:reply, Reply.text(Jason.encode!(decoded)), session}
          {:error, _} -> {:reply, Reply.text(bin), session}
        end
    end
  end

  defp resolve(%{assigns: %{sark_auth: v}}, _opts) when is_binary(v), do: v
  defp resolve(_session, opts), do: Keyword.get(opts, :sark_auth)
end

defmodule Sark.URL do
  @moduledoc """
  Builds the externally-visible base URL for sark.

  When the `:url` app env is set (from `config.url`) it wins — this is
  the deployment-behind-proxy case where `conn.host` / `conn.scheme`
  reflect the proxy hop, not what clients see. Otherwise derive from
  the incoming conn (correct for local + single-host deployments).

  Used to build:

    * `Sark.AuthPlug`'s `WWW-Authenticate` challenge `resource_metadata=`
      URL on 401.
    * `Sark.Endpoint`'s `resource` field in the protected-resource
      metadata document.

  Both must point at URLs the **client** can actually reach.
  """

  @spec base(Plug.Conn.t()) :: String.t()
  def base(%Plug.Conn{} = conn) do
    case Application.get_env(:sark, :url) do
      nil -> from_conn(conn)
      url when is_binary(url) -> url
    end
  end

  defp from_conn(%Plug.Conn{scheme: scheme, host: host, port: port}) do
    s = Atom.to_string(scheme)

    port_part =
      case {s, port} do
        {"http", 80} -> ""
        {"https", 443} -> ""
        {_, p} -> ":#{p}"
      end

    "#{s}://#{host}#{port_part}"
  end
end

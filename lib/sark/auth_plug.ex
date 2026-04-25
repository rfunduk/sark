defmodule Sark.AuthPlug do
  @moduledoc """
  Bearer-token gate. `/health` is exempt for unauthenticated liveness.
  On success, assigns `:token_name` to the conn for downstream logging.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @exempt_paths ["/health"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.request_path in @exempt_paths do
      conn
    else
      authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with [auth] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth,
         {:ok, name} <- Sark.AuthRegistry.lookup(token) do
      assign(conn, :token_name, name)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end

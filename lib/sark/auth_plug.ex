defmodule Sark.AuthPlug.Scope do
  @moduledoc false
  # Pulled out so AuthPlug can call into Endpoint's path_info without
  # circular config: route shape is `/<plugin>/mcp[/...]`.

  @spec plugin_from_path([String.t()]) :: {:ok, String.t()} | :error
  def plugin_from_path([plugin, "mcp" | _]) when is_binary(plugin), do: {:ok, plugin}
  def plugin_from_path(_), do: :error
end

defmodule Sark.AuthPlug do
  @moduledoc """
  Bearer-token gate + per-plugin scope check.

  Routing shape: `/<plugin>/mcp[/...]`. `/health` is exempt for
  unauthenticated liveness; everything else requires a bearer.

  Response codes:

    * bad/missing token → 401
    * good token, plugin not in scope (or unknown plugin) → 404 — both
      collapse to the same status so a token can't enumerate plugin
      names

  On success, assigns `:token_name` + `:plugin` for downstream handlers.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  alias Sark.AuthPlug.Scope
  alias Sark.AuthRegistry

  @exempt_paths [["health"]]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.path_info in @exempt_paths do
      conn
    else
      authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with [auth] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth,
         {:ok, %{name: name} = entry} <- AuthRegistry.lookup(token) do
      authorize(conn, entry, name)
    else
      _ -> unauthorized(conn)
    end
  end

  defp authorize(conn, entry, name) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        if AuthRegistry.authorized?(entry, plugin) do
          conn
          |> assign(:token_name, name)
          |> assign(:plugin, plugin)
        else
          not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not found"}))
    |> halt()
  end
end

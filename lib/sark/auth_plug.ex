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

  Token sources (checked in order):

    1. `Authorization: Bearer <token>` header
    2. `?token=<token>` query string param (fallback for clients
       that can't set custom headers, e.g. Claude for Web)

  Response codes:

    * bad/missing token → 401
    * good token, plugin not in scope (or unknown plugin) → 404 — both
      collapse to the same status so a token can't enumerate plugin
      names

  On success, assigns `:token_name` + `:plugin` for downstream handlers.

  Also assigns `:sark_auth` — a JSON-encoded envelope describing the
  caller's identity. Synthesized here in JWT-like shape:

      {"sub": "token:<name>", "name": "<name>", "iss": "sark.bearer"}

  Phantom router's `connect/2` copies this onto `session.assigns` so
  tool handlers can inject it as the `:sark_auth` SQL binding. Plugins
  reach for the parts they want via `json_extract`, e.g.
  `json_extract(:sark_auth, '$.sub')`. Sark provides, plugin decides.
  """

  @behaviour Plug
  import Plug.Conn

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
    case extract_token(conn) do
      {:ok, token} ->
        case AuthRegistry.lookup(token) do
          {:ok, %{name: name} = entry} -> authorize(conn, entry, name)
          _ -> unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, token}

      _ ->
        conn = fetch_query_params(conn)

        case conn.query_params do
          %{"token" => token} when is_binary(token) and token != "" -> {:ok, token}
          _ -> :error
        end
    end
  end

  defp authorize(conn, entry, name) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        if AuthRegistry.authorized?(entry, plugin) do
          conn
          |> assign(:token_name, name)
          |> assign(:plugin, plugin)
          |> assign(:token_entry, entry)
          |> assign(:sark_auth, bearer_envelope(name))
        else
          not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  defp bearer_envelope(name) do
    Jason.encode!(%{
      "sub" => "token:" <> name,
      "name" => name,
      "iss" => "sark.bearer"
    })
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

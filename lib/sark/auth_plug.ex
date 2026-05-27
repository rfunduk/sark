defmodule Sark.AuthPlug.Scope do
  @moduledoc false
  # Pulled out so AuthPlug can call into Endpoint's path_info without
  # circular config: route shape is `/<plugin>/mcp[/...]`.

  @spec plugin_from_path([String.t()]) :: {:ok, String.t()} | :error
  def plugin_from_path([plugin, "mcp" | _]) when is_binary(plugin), do: {:ok, plugin}
  def plugin_from_path(_), do: :error

  @spec well_known?([String.t()]) :: boolean
  def well_known?([_plugin, ".well-known", "oauth-protected-resource"]), do: true
  def well_known?([".well-known", "oauth-authorization-server"]), do: true
  def well_known?(_), do: false

  @spec oauth_broker?([String.t()]) :: boolean
  def oauth_broker?(["oauth", "authorize"]), do: true
  def oauth_broker?(["oauth", "token"]), do: true
  def oauth_broker?(_), do: false
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

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if exempt?(conn.path_info) do
      conn
    else
      authenticate(conn)
    end
  end

  defp exempt?(["health"]), do: true
  defp exempt?(path), do: Scope.well_known?(path) or Scope.oauth_broker?(path)

  defp authenticate(conn) do
    case extract_token(conn) do
      {:ok, token} -> resolve(conn, token)
      :error -> unauthorized(conn)
    end
  end

  # Resolution order when an IdP is configured:
  #
  #   1. Try the token as a JWT. Any JWT-specific failure (bad sig,
  #      expired, wrong aud/iss) → straight to 401. We don't fall
  #      through to the bearer table because the client clearly meant
  #      to send a JWT.
  #   2. `:bad_format` (token isn't a JWT at all) → fall through to
  #      bearer-token lookup. Lets bearer tokens and JWT users coexist.
  #
  # Without an IdP, only the bearer path runs.
  defp resolve(conn, token) do
    case Application.get_env(:sark, :idp) do
      nil -> resolve_bearer(conn, token)
      idp -> resolve_jwt(conn, token, idp)
    end
  end

  defp resolve_jwt(conn, token, idp) do
    case Sark.Auth.JWT.verify(token, idp) do
      {:ok, claims} ->
        authorize_jwt(conn, claims)

      {:error, :bad_format} ->
        require Logger
        Logger.debug("auth: token is not a JWT, falling through to bearer table")
        resolve_bearer(conn, token)

      {:error, reason} ->
        require Logger
        Logger.warning("auth: JWT verify failed — #{inspect(reason)}")
        unauthorized(conn)
    end
  end

  defp resolve_bearer(conn, token) do
    case AuthRegistry.lookup(token) do
      {:ok, %{name: name} = entry} -> authorize_bearer(conn, entry, name)
      _ -> unauthorized(conn)
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

  defp authorize_bearer(conn, entry, name) do
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

  # JWT path: every valid JWT for the configured IdP grants access to
  # every plugin. Per-plugin scoping (mirror of the bearer allow-list)
  # arrives in Phase 4 — for now we only check the token's `aud` matches
  # this sark instance, and trust any caller the IdP vouches for.
  defp authorize_jwt(conn, claims) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        conn
        |> assign(:token_name, jwt_display_name(claims))
        |> assign(:plugin, plugin)
        |> assign(:sark_auth, Jason.encode!(claims))

      :error ->
        not_found(conn)
    end
  end

  defp jwt_display_name(claims) do
    claims["preferred_username"] || claims["email"] || claims["name"] || claims["sub"] || "jwt"
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
    |> with_challenge()
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end

  # Per RFC 9728 / MCP 2025-06-18: a 401 from a protected resource SHOULD
  # carry a `WWW-Authenticate: Bearer resource_metadata="<url>"` header
  # pointing at the resource's protected-resource metadata document. The
  # client follows the pointer to discover auth-server config. Without
  # this header, MCP clients (Claude.ai, Claude Code) cannot tell apart
  # "typo'd bearer token" from "this server isn't OAuth-configured", and
  # they default to telling the user the server is misconfigured.
  #
  # Only attached when the path is `/<plugin>/mcp[/...]` — we need a
  # plugin name to build the metadata URL.
  defp with_challenge(conn) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        url = metadata_url(conn, plugin)
        put_resp_header(conn, "www-authenticate", ~s|Bearer resource_metadata="#{url}"|)

      :error ->
        conn
    end
  end

  defp metadata_url(conn, plugin) do
    "#{Sark.URL.base(conn)}/#{plugin}/.well-known/oauth-protected-resource"
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not found"}))
    |> halt()
  end
end

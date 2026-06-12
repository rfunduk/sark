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
  def well_known?([_plugin, ".well-known", "oauth-authorization-server"]), do: true
  def well_known?([".well-known", "oauth-authorization-server", _plugin]), do: true
  def well_known?(_), do: false

  @spec oauth_broker?([String.t()]) :: boolean
  def oauth_broker?(["oauth", "authorize"]), do: true
  def oauth_broker?([_plugin, "oauth", "authorize"]), do: true
  def oauth_broker?(["oauth", "callback"]), do: true
  def oauth_broker?(["oauth", "token"]), do: true
  def oauth_broker?(["oauth", "register"]), do: true
  def oauth_broker?(_), do: false
end

defmodule Sark.AuthPlug do
  @moduledoc """
  Bearer-token gate + per-plugin scope check.

  Routing shape: `/<plugin>/mcp[/...]`. `/health` is exempt for
  unauthenticated liveness; everything else requires a bearer — unless
  the operator set `auth: none`, which makes every request anonymous
  (`{"sub": "anon", "iss": "sark.none"}` envelope, full plugin access).

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
    cond do
      exempt?(conn.path_info) -> conn
      conn.path_info == ["mcp"] -> missing_plugin(conn)
      Application.get_env(:sark, :auth_none, false) -> anonymous(conn)
      true -> authenticate(conn)
    end
  end

  # `auth: none` — explicit operator opt-out of authentication. Every
  # plugin-shaped request passes with full access and a synthesized
  # envelope, so plugin SQL reading `:sark_auth` keeps working.
  defp anonymous(conn) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        conn
        |> assign(:token_name, "anon")
        |> assign(:plugin, plugin)
        |> assign(:token_entry, %{name: "anon", allowed: :all})
        |> assign(:sark_auth, anon_envelope())

      :error ->
        not_found(conn)
    end
  end

  defp anon_envelope do
    Jason.encode!(%{"sub" => "anon", "name" => "anon", "iss" => "sark.none"})
  end

  # Bare `/mcp` (no plugin segment) is the classic mis-pasted client URL.
  # A plain 401 here can't carry a resource_metadata challenge (no plugin
  # to build it from), so the client falls back to root-level discovery
  # and fails much later at /oauth/authorize with an unrelated-looking
  # error. Name the actual mistake at the first request instead.
  defp missing_plugin(conn) do
    body =
      Jason.encode!(%{
        "error" => "not_found",
        "error_description" =>
          "no MCP endpoint at /mcp — endpoints on this server look like " <>
            "/<name>/mcp; check the URL you were given"
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
    |> halt()
  end

  defp exempt?(["health"]), do: true
  defp exempt?(path), do: Scope.well_known?(path) or Scope.oauth_broker?(path)

  defp authenticate(conn) do
    case extract_token(conn) do
      {:ok, token} -> resolve(conn, token)
      :error -> unauthorized(conn)
    end
  end

  # Resolution order:
  #
  #   1. `sk-sark-*` token → per-plugin `_sessions` lookup. Most
  #      common path once a user has done the OAuth dance.
  #   2. JWT verify (when IdP configured). Direct id_token path —
  #      mostly useful for testing / custom clients that bypass the
  #      broker.
  #   3. Bearer-token table.
  defp resolve(conn, token) do
    cond do
      Sark.Auth.Session.session_token?(token) ->
        resolve_session(conn, token)

      Application.get_env(:sark, :idp) != nil ->
        resolve_jwt(conn, token, Application.get_env(:sark, :idp))

      true ->
        resolve_bearer(conn, token)
    end
  end

  defp resolve_session(conn, token) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        with {:ok, row} <- Sark.Auth.Session.lookup(plugin, token),
             idp = Application.get_env(:sark, :idp),
             {:ok, %{"claims" => claims}} <- Sark.OAuth.Refresh.maybe_refresh(plugin, row, idp) do
          authorize_jwt(conn, claims)
        else
          _ -> unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
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

  # JWT path: if `auth.idp.rules:` is configured, evaluate claims against
  # rules to derive the effective plugin scope. Otherwise fall through to
  # legacy behavior (every valid JWT reaches every plugin).
  defp authorize_jwt(conn, claims) do
    case Scope.plugin_from_path(conn.path_info) do
      {:ok, plugin} ->
        conn
        |> assign(:token_name, jwt_display_name(claims))
        |> assign(:plugin, plugin)
        |> assign(:sark_auth, Jason.encode!(claims))
        |> apply_rules(claims, plugin)

      :error ->
        not_found(conn)
    end
  end

  # JWT/session callers are always rules-gated. `auth.idp.rules:` absent
  # or empty ⇒ zero matches ⇒ default deny. No back-compat "every JWT
  # gets everything" path — opt-in by writing an explicit
  # `{ match: { path: sub, exists: true }, plugins: [ALL] }` rule.
  defp apply_rules(conn, claims, plugin) do
    case Application.get_env(:sark, :idp) do
      %Sark.Config.IdP{rules: rules} ->
        case Sark.Auth.Rules.eval(claims, rules) do
          :deny ->
            forbidden(conn)

          allowed ->
            entry = %{name: conn.assigns[:token_name] || "jwt", allowed: allowed}

            if Sark.AuthRegistry.authorized?(entry, plugin) do
              assign(conn, :token_entry, entry)
            else
              not_found(conn)
            end
        end

      _ ->
        conn
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

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, ~s({"error":"forbidden","reason":"no matching auth rule"}))
    |> halt()
  end
end

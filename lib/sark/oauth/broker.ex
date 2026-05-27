defmodule Sark.OAuth.Broker do
  @moduledoc """
  Thin OAuth 2.1 proxy. Sits between MCP clients (Claude Code, claude.ai
  web, codex, custom scripts) and the configured upstream IdP. Clients
  treat sark as the authorization server; sark forwards to upstream.

  Endpoints:

    * `GET /oauth/authorize` — 302 to upstream `authorization_endpoint`
      with the client's query params; inject `scope=openid email profile`
      if absent. The client's RFC 8707 `resource=` param identifies
      which plugin the resulting session belongs to — sark stashes
      `code_challenge → plugin` (see `Sark.OAuth.Correlator`) so the
      `/token` exchange can route the resulting session row to the
      right `<plugin>.sark.db`.

    * `POST /oauth/token` — form-POST proxy to upstream. Inject
      `client_secret` from config. On success, extract claims from the
      upstream id_token, write a row to `_sessions` in the matched
      plugin's sark DB, and return a sark-issued `sk-sark-<random>`
      token to the client as `access_token` (clients never see
      upstream JWTs).

  This isolates clients from IdP quirks (Google's opaque access tokens,
  refresh-token id_token absence, etc). Once a session is established,
  AuthPlug looks it up directly; no per-request upstream calls.
  """

  import Plug.Conn

  alias Sark.Auth.JWT
  alias Sark.Auth.KeyStore
  alias Sark.Auth.Session
  alias Sark.Config.IdP
  alias Sark.OAuth.Correlator

  # Default session lifetime when upstream doesn't give us `expires_in`
  # on the token response. JIT refresh keeps it perpetually fresh as
  # long as upstream refresh succeeds.
  @default_expires_in_sec 3600

  @passthrough_authorize_params ~w(response_type client_id redirect_uri state code_challenge code_challenge_method scope resource)
  @passthrough_token_params ~w(grant_type code redirect_uri code_verifier refresh_token client_id resource)

  @spec authorize(Plug.Conn.t()) :: Plug.Conn.t()
  def authorize(conn) do
    with {:ok, idp} <- idp(),
         {:ok, upstream} <- KeyStore.fetch_endpoint("authorization_endpoint") do
      conn = fetch_query_params(conn)
      params = build_authorize_params(conn.query_params, idp)
      stash_plugin_correlation(conn.query_params)
      target = upstream <> "?" <> URI.encode_query(params)

      conn
      |> put_resp_header("location", target)
      |> send_resp(302, "")
    else
      {:error, reason} -> send_broker_error(conn, "authorize_failed", reason)
    end
  end

  @spec token(Plug.Conn.t()) :: Plug.Conn.t()
  def token(conn) do
    body = conn.body_params || %{}

    with {:ok, idp} <- idp(),
         {:ok, plugin} <- resolve_plugin(body),
         {:ok, upstream} <- KeyStore.fetch_endpoint("token_endpoint"),
         params = build_token_params(body, idp),
         {:ok, upstream_body} <- post_upstream(upstream, params),
         {:ok, claims} <- verify_id_token(upstream_body, idp),
         {:ok, session_token} <- create_session(plugin, claims, upstream_body) do
      forget_correlation(body)

      response = build_session_response(session_token, upstream_body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    else
      {:error, reason} -> send_broker_error(conn, "token_failed", reason)
    end
  end

  defp resolve_plugin(body) do
    case Map.get(body, "code_verifier") do
      v when is_binary(v) and v != "" ->
        case Correlator.lookup(v) do
          {:ok, plugin} -> {:ok, plugin}
          :not_found -> {:error, :unknown_plugin_correlation}
        end

      _ ->
        # Refresh-grant calls don't have code_verifier. Defer per-plugin
        # routing for now — refresh grant handled in Phase 4 step 3.
        {:error, :refresh_grant_not_yet_supported}
    end
  end

  defp stash_plugin_correlation(query) do
    with code_challenge when is_binary(code_challenge) <- Map.get(query, "code_challenge"),
         resource when is_binary(resource) <- Map.get(query, "resource"),
         {:ok, plugin} <- plugin_from_resource(resource) do
      Correlator.stash(code_challenge, plugin)
    else
      _ -> :ok
    end
  end

  # `resource` is a URL like `https://sark.example.com/openfig/mcp`.
  # Pull the plugin segment (the one before `/mcp`).
  defp plugin_from_resource(url) do
    uri = URI.parse(url)
    segments = String.split(uri.path || "", "/", trim: true)

    case Enum.reverse(segments) do
      ["mcp", plugin | _] -> {:ok, plugin}
      _ -> :error
    end
  end

  defp forget_correlation(%{"code_verifier" => v}) when is_binary(v), do: Correlator.forget(v)
  defp forget_correlation(_), do: :ok

  defp post_upstream(url, params) do
    case Req.post(req(), url: url, form: params) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, decode_body(body)}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:upstream, status, body}}
      {:error, reason} -> {:error, {:upstream_unreachable, reason}}
    end
  end

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp verify_id_token(%{"id_token" => id_token}, %IdP{} = idp) when is_binary(id_token) do
    case JWT.verify(id_token, idp) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, {:id_token_invalid, reason}}
    end
  end

  defp verify_id_token(_, _), do: {:error, :missing_id_token}

  defp create_session(plugin, claims, upstream_body) do
    expires_at = compute_expiry(upstream_body)
    refresh = Map.get(upstream_body, "refresh_token")
    Session.create(plugin, claims, refresh, expires_at)
  end

  defp compute_expiry(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now() |> DateTime.add(seconds, :second)
  end

  defp compute_expiry(_) do
    DateTime.utc_now() |> DateTime.add(@default_expires_in_sec, :second)
  end

  # Sark session token's client-visible lifetime. Decoupled from
  # upstream's `expires_in` — sark JIT-refreshes the upstream token
  # transparently behind the scenes (see `Sark.OAuth.Refresh`). If we
  # forwarded upstream's 1h expiry here, MCP clients (Claude Code etc.)
  # would discard their session token after an hour without ever
  # giving sark a chance to refresh it.
  #
  # 30 days = balance between "feels durable" and "client should redo
  # OAuth occasionally to recover from server-side cleanup / IdP key
  # rotation / revocation we haven't propagated".
  @session_lifetime_sec 30 * 24 * 3600

  # Return a spec-shaped OAuth token response w/ sark's session token
  # in `access_token`. Clients don't need (and shouldn't see) the
  # upstream id_token or refresh_token.
  defp build_session_response(session_token, _upstream_body) do
    %{
      "access_token" => session_token,
      "token_type" => "Bearer",
      "expires_in" => @session_lifetime_sec
    }
  end

  defp idp do
    case Application.get_env(:sark, :idp) do
      %IdP{} = idp -> {:ok, idp}
      _ -> {:error, :no_idp}
    end
  end

  # Inject scope only if the client didn't supply one. Drop anything not
  # on the passthrough list so the redirect to upstream stays minimal.
  #
  # Also inject `access_type=offline` + `prompt=consent`:
  #   - Google requires `access_type=offline` to issue a refresh_token
  #     at all. Without it Google returns access_token + id_token only,
  #     no refresh_token, sark sessions die at id_token expiry.
  #   - `prompt=consent` forces Google to reissue refresh_token even
  #     when the user has previously consented. Costs a consent screen
  #     per OAuth flow; in exchange sark always gets a usable refresh
  #     token (otherwise: first dance gets one, every subsequent dance
  #     against the same client_id+sub leaves refresh_token NULL).
  # Other IdPs (Okta, Auth0, etc.) typically ignore unknown params, so
  # these don't break the non-Google path. Operators wanting refresh
  # tokens from Okta-style providers should add `offline_access` to
  # their token scope config (Phase 4 follow-up).
  defp build_authorize_params(query, %IdP{} = idp) do
    base =
      Enum.reduce(@passthrough_authorize_params, [], fn key, acc ->
        case Map.get(query, key) do
          v when is_binary(v) and v != "" -> [{key, v} | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    base
    |> ensure_param("scope", Enum.join(IdP.effective_scope(idp), " "))
    |> ensure_param("access_type", "offline")
    |> ensure_param("prompt", "consent")
  end

  # Forward what the client sent; overwrite client_secret w/ our own.
  # Some upstream IdPs accept client_secret in body, some require Basic
  # auth — body form is the most portable.
  defp build_token_params(body, %IdP{client_id: client_id, client_secret: secret}) do
    forwarded =
      Enum.reduce(@passthrough_token_params, [], fn key, acc ->
        case Map.get(body, key) do
          v when is_binary(v) and v != "" -> [{key, v} | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    forwarded
    |> ensure_param("client_id", client_id)
    |> ensure_param("client_secret", secret)
  end

  defp ensure_param(list, _key, nil), do: list
  defp ensure_param(list, _key, ""), do: list

  defp ensure_param(list, key, value) do
    case Enum.find_index(list, fn {k, _} -> k == key end) do
      nil -> list ++ [{key, value}]
      idx -> List.replace_at(list, idx, {key, value})
    end
  end

  defp send_broker_error(conn, code, reason) do
    body = Jason.encode!(%{"error" => code, "error_description" => inspect(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(502, body)
  end

  defp req do
    case Application.get_env(:sark, :req_plug) do
      nil -> Req.new()
      plug -> Req.new(plug: plug)
    end
  end
end

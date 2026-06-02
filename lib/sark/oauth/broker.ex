defmodule Sark.OAuth.Broker do
  @moduledoc """
  Full OAuth 2.1 broker. Sits between MCP clients (Claude Code, claude.ai
  web, codex, custom scripts) and the configured upstream IdP. Clients
  treat sark as the authorization server; sark federates to upstream.

  Sark is *literally* the authorization server from the client's view —
  it terminates the upstream OAuth dance at its own fixed
  `/oauth/callback` and re-issues a sark-minted code to the client's own
  (random, ephemeral) localhost redirect_uri. This is the standard
  identity-broker pattern (Auth0/Cognito/Keycloak do the same fronting
  upstream IdPs), and it sidesteps the redirect_uri problem: Okta (and
  Auth0) only support *subdomain* wildcards, not wildcard loopback ports,
  so the operator registers ONE fixed callback and sark bridges the
  varying client port behind it.

  Endpoints:

    * `GET /oauth/authorize` — downstream client → sark. Mint an opaque
      `sark_state`, stash the client's `{redirect_uri, state, PKCE
      challenge, plugin}` under it (the plugin comes from the RFC 8707
      `resource=` param), then 302 to upstream `authorization_endpoint`
      with sark's *own* fixed `redirect_uri` (`/oauth/callback`) and
      `state=sark_state`. The client's redirect_uri + PKCE challenge
      never reach upstream.

    * `GET /oauth/callback` — upstream → sark. Pop the authorize context
      by `sark_state`, mint an opaque `sark_code`, stash the upstream
      auth code under it, then 302 to the client's original redirect_uri
      with `code=sark_code` and the client's original `state`. Upstream
      `error=` responses are bridged back to the client the same way.

    * `POST /oauth/token` — downstream client → sark. Pop the token
      context by `sark_code`, verify the client's PKCE `code_verifier`
      against the stashed challenge (sark terminates downstream PKCE —
      the verifier never reaches upstream), then POST the *upstream* auth
      code to the upstream token endpoint with `client_secret` injected
      from config. On success, extract claims from the upstream id_token,
      write a row to `_sessions` in the matched plugin's sark DB, and
      return a sark-issued `sk-sark-<random>` token to the client as
      `access_token` (clients never see upstream JWTs).

    * `POST /oauth/register` — RFC 7591 dynamic client registration
      stub. Stateless: every caller gets the same pre-configured
      `client_id` (sark is one shared upstream client; there's no
      per-client identity to mint). Advertises `none` auth method —
      downstream MCP clients are public (PKCE), and sark injects the
      real `client_secret` upstream on `/token`. The secret never
      leaves the server. Exists only to satisfy spec-strict MCP
      clients that refuse auth servers lacking a `registration_endpoint`.

  Upstream PKCE: the configured Okta/Auth0 app is a confidential (Web)
  client — sark authenticates upstream with `client_secret`, so it does
  NOT do PKCE on the upstream leg. Downstream PKCE (client↔sark) is still
  verified by sark. A public upstream app (no secret) would need sark to
  run PKCE upstream too; not implemented — `client_secret` is required
  for the broker flow.

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

  # Correlation TTLs. Authorize → callback spans an interactive login;
  # callback → token is an immediate machine exchange.
  @authorize_ttl_ms 5 * 60 * 1000
  @code_ttl_ms 60 * 1000

  @spec authorize(Plug.Conn.t()) :: Plug.Conn.t()
  def authorize(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, idp} <- idp(),
         {:ok, upstream} <- KeyStore.fetch_endpoint("authorization_endpoint"),
         {:ok, ctx} <- build_authorize_ctx(query) do
      sark_state = gen_token()
      Correlator.stash("state:" <> sark_state, ctx, @authorize_ttl_ms)

      params = build_upstream_authorize_params(query, idp, sark_state, callback_url(conn))
      target = upstream <> "?" <> URI.encode_query(params)
      redirect(conn, target)
    else
      {:error, reason} -> send_broker_error(conn, "authorize_failed", reason)
    end
  end

  @spec callback(Plug.Conn.t()) :: Plug.Conn.t()
  def callback(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    case fetch_param(query, "state") do
      {:ok, sark_state} ->
        case Correlator.pop("state:" <> sark_state) do
          {:ok, ctx} -> resume_callback(conn, query, ctx)
          :not_found -> send_broker_error(conn, "callback_failed", :unknown_or_expired_state)
        end

      {:error, reason} ->
        send_broker_error(conn, "callback_failed", reason)
    end
  end

  # Upstream finished. Bridge either the auth code or an upstream error
  # back to the downstream client's original redirect_uri.
  defp resume_callback(conn, query, ctx) do
    case query do
      %{"error" => error} ->
        bridge_to_client(conn, ctx, %{"error" => error}, query["error_description"])

      %{"code" => upstream_code} when is_binary(upstream_code) and upstream_code != "" ->
        sark_code = gen_token()

        token_ctx = %{
          upstream_code: upstream_code,
          code_challenge: ctx.code_challenge,
          code_challenge_method: ctx.code_challenge_method,
          plugin: ctx.plugin
        }

        Correlator.stash("code:" <> sark_code, token_ctx, @code_ttl_ms)
        bridge_to_client(conn, ctx, %{"code" => sark_code}, nil)

      _ ->
        send_broker_error(conn, "callback_failed", :upstream_missing_code)
    end
  end

  defp bridge_to_client(conn, ctx, params, error_description) do
    params =
      params
      |> maybe_put("state", ctx.client_state)
      |> maybe_put("error_description", error_description)

    sep = if String.contains?(ctx.client_redirect_uri, "?"), do: "&", else: "?"
    target = ctx.client_redirect_uri <> sep <> URI.encode_query(params)
    redirect(conn, target)
  end

  @spec token(Plug.Conn.t()) :: Plug.Conn.t()
  def token(conn) do
    body = conn.body_params || %{}

    with {:ok, idp} <- idp(),
         {:ok, ctx} <- resolve_token_ctx(body),
         :ok <- verify_client_pkce(body, ctx),
         {:ok, basic} <- upstream_basic_auth(idp),
         {:ok, upstream} <- KeyStore.fetch_endpoint("token_endpoint"),
         params = build_upstream_token_params(ctx, callback_url(conn)),
         {:ok, upstream_body} <- post_upstream(upstream, params, basic),
         {:ok, claims} <- verify_id_token(upstream_body, idp),
         {:ok, session_token} <- create_session(ctx.plugin, claims, upstream_body) do
      response = build_session_response(session_token, upstream_body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    else
      {:error, reason} -> send_broker_error(conn, "token_failed", reason)
    end
  end

  # --- DCR (RFC 7591) ---------------------------------------------------------

  # Stateless projection of `auth.idp` config into the registration-response
  # shape — no storage, same `client_id` every time. Echoes the client's
  # `redirect_uris` (RFC 7591 requires them in the response) and advertises
  # `none` so public clients use PKCE; sark holds the real secret upstream.
  @spec register(Plug.Conn.t()) :: Plug.Conn.t()
  def register(conn) do
    with {:ok, idp} <- idp(),
         {:ok, client_id} <- registration_client_id(idp) do
      response = build_registration_response(client_id, conn.body_params || %{})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(response))
    else
      {:error, reason} -> send_broker_error(conn, "registration_failed", reason)
    end
  end

  defp registration_client_id(%IdP{client_id: id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp registration_client_id(_), do: {:error, :no_client_id_configured}

  defp build_registration_response(client_id, body) do
    %{
      "client_id" => client_id,
      "client_id_issued_at" => System.system_time(:second),
      "token_endpoint_auth_method" => "none",
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "redirect_uris" => echo_redirect_uris(body)
    }
  end

  defp echo_redirect_uris(%{"redirect_uris" => uris}) when is_list(uris), do: uris
  defp echo_redirect_uris(_), do: []

  # --- authorize context ------------------------------------------------------

  # Pull the downstream client's request into a context we stash for the
  # callback. PKCE challenge + a loopback-or-https redirect are required —
  # MCP clients are public clients (OAuth 2.1 mandates PKCE).
  defp build_authorize_ctx(query) do
    with {:ok, redirect_uri} <- fetch_param(query, "redirect_uri"),
         :ok <- validate_client_redirect(redirect_uri),
         {:ok, code_challenge} <- fetch_param(query, "code_challenge"),
         {:ok, resource} <- fetch_param(query, "resource"),
         {:ok, plugin} <- plugin_from_resource(resource) do
      {:ok,
       %{
         client_redirect_uri: redirect_uri,
         client_state: Map.get(query, "state"),
         code_challenge: code_challenge,
         code_challenge_method: Map.get(query, "code_challenge_method", "S256"),
         plugin: plugin
       }}
    end
  end

  # Accept https anywhere; http only for loopback. Blocks an attacker
  # redirecting the bridged code to an arbitrary http origin (defence in
  # depth — PKCE already binds the exchange).
  defp validate_client_redirect(uri_str) do
    uri = URI.parse(uri_str)

    case {uri.scheme, uri.host} do
      {"https", h} when is_binary(h) and h != "" -> :ok
      {"http", h} when h in ["localhost", "127.0.0.1", "::1"] -> :ok
      _ -> {:error, {:invalid_redirect_uri, uri_str}}
    end
  end

  # `resource` is a URL like `https://sark.example.com/openfig/mcp`.
  # Pull the plugin segment (the one before `/mcp`).
  defp plugin_from_resource(url) do
    uri = URI.parse(url)
    segments = String.split(uri.path || "", "/", trim: true)

    case Enum.reverse(segments) do
      ["mcp", plugin | _] -> {:ok, plugin}
      _ -> {:error, {:bad_resource, url}}
    end
  end

  # --- token context + PKCE ---------------------------------------------------

  defp resolve_token_ctx(body) do
    case Map.get(body, "grant_type") do
      "authorization_code" ->
        case fetch_param(body, "code") do
          {:ok, sark_code} ->
            case Correlator.pop("code:" <> sark_code) do
              {:ok, ctx} -> {:ok, ctx}
              :not_found -> {:error, :unknown_or_expired_code}
            end

          {:error, reason} ->
            {:error, reason}
        end

      "refresh_token" ->
        # Refresh-grant routing deferred — sessions JIT-refresh upstream
        # internally (see `Sark.OAuth.Refresh`); clients don't refresh
        # against the broker.
        {:error, :refresh_grant_not_supported}

      other ->
        {:error, {:unsupported_grant_type, other}}
    end
  end

  # Sark terminates downstream PKCE: the client proves possession of the
  # verifier to sark (not upstream). Verifier never leaves for upstream.
  defp verify_client_pkce(body, ctx) do
    with {:ok, verifier} <- fetch_param(body, "code_verifier") do
      case ctx.code_challenge_method do
        "S256" ->
          if pkce_s256(verifier) == ctx.code_challenge,
            do: :ok,
            else: {:error, :pkce_mismatch}

        "plain" ->
          if verifier == ctx.code_challenge,
            do: :ok,
            else: {:error, :pkce_mismatch}

        other ->
          {:error, {:unsupported_code_challenge_method, other}}
      end
    end
  end

  defp pkce_s256(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  # --- upstream parameter builders --------------------------------------------

  # Sark's own request to upstream. Inject sark's fixed redirect_uri +
  # opaque state; drop the client's redirect_uri / state / PKCE challenge
  # (downstream concerns). Inject baseline scope when absent.
  #
  # `access_type=offline` + `prompt=consent` for Google refresh tokens;
  # other IdPs ignore unknown params. Operators wanting refresh from
  # spec-clean IdPs (Okta etc.) add `offline_access` to `auth.idp.scope`.
  defp build_upstream_authorize_params(query, %IdP{} = idp, sark_state, redirect_uri) do
    base = [
      {"response_type", "code"},
      {"client_id", idp.client_id},
      {"redirect_uri", redirect_uri},
      {"state", sark_state},
      {"scope", Enum.join(IdP.effective_scope(idp), " ")}
    ]

    base
    |> maybe_append_param("resource", Map.get(query, "resource"))
    |> ensure_param("access_type", "offline")
    |> ensure_param("prompt", "consent")
  end

  # Upstream token exchange. Send the *upstream* auth code + sark's fixed
  # redirect_uri (must match what we sent at authorize). Client credentials
  # go via HTTP Basic (`client_secret_basic`) — see `upstream_basic_auth/1`.
  # No code_verifier upstream — sark is a confidential client there.
  defp build_upstream_token_params(ctx, redirect_uri) do
    [
      {"grant_type", "authorization_code"},
      {"code", ctx.upstream_code},
      {"redirect_uri", redirect_uri}
    ]
  end

  # Confidential-client auth for the upstream token call. HTTP Basic
  # (`client_secret_basic`) is the OAuth 2.0 default (RFC 6749 §2.3) and
  # the Okta/Auth0 Web-app default; Google accepts it too. Sending the
  # secret in the form body (`client_secret_post`) instead trips Okta's
  # `invalid_client` when the app is configured for Basic.
  defp upstream_basic_auth(%IdP{client_id: id, client_secret: secret})
       when is_binary(id) and is_binary(secret) and secret != "" do
    {:ok, {:basic, id <> ":" <> secret}}
  end

  defp upstream_basic_auth(_), do: {:error, :missing_client_secret}

  # --- upstream call + session ------------------------------------------------

  defp post_upstream(url, params, auth) do
    case Req.post(req(), url: url, form: params, auth: auth) do
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

  # --- helpers ----------------------------------------------------------------

  defp idp do
    case Application.get_env(:sark, :idp) do
      %IdP{} = idp -> {:ok, idp}
      _ -> {:error, :no_idp}
    end
  end

  defp callback_url(conn), do: Sark.URL.base(conn) <> "/oauth/callback"

  defp gen_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp fetch_param(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_param, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_param(list, _key, nil), do: list
  defp maybe_append_param(list, _key, ""), do: list
  defp maybe_append_param(list, key, value), do: list ++ [{key, value}]

  defp ensure_param(list, key, value) do
    case Enum.find_index(list, fn {k, _} -> k == key end) do
      nil -> list ++ [{key, value}]
      idx -> List.replace_at(list, idx, {key, value})
    end
  end

  defp redirect(conn, target) do
    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
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

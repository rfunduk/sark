defmodule Sark.OAuth.Broker do
  @moduledoc """
  Thin OAuth 2.1 proxy. Sits between MCP clients (Claude Code, claude.ai
  web, codex, custom scripts) and the configured upstream IdP. Clients
  treat sark as the authorization server; sark forwards to upstream.

  Why broker instead of resource-only? Most MCP clients don't yet
  implement MCP spec 2025-06-18's split between resource server and
  authorization server. They expect the MCP server URL to host
  `/oauth/authorize` + `/oauth/token` directly. Brokering through sark
  makes those clients work against any upstream IdP without per-client
  changes.

  Two endpoints:

    * `GET /oauth/authorize` — 302 to upstream `authorization_endpoint`
      with the same query params; inject `scope=openid email profile`
      if the client didn't send one. PKCE (`code_challenge` /
      `code_challenge_method`) passes through unchanged. State is the
      client's responsibility — sark stores nothing.

    * `POST /oauth/token` — form-POST proxy to upstream `token_endpoint`.
      Inject `client_secret` from config (clients don't have it).
      Pass through `grant_type`, `code`, `code_verifier`, `redirect_uri`,
      `client_id`, `refresh_token`.

  No state, no cache, no rate limit. PKCE state lives in the client's
  cookie/storage and in the upstream's authorization_code; sark stays
  stateless.
  """

  import Plug.Conn
  alias Sark.Auth.KeyStore
  alias Sark.Config.IdP

  @default_scope "openid email profile"

  @passthrough_authorize_params ~w(response_type client_id redirect_uri state code_challenge code_challenge_method scope)
  @passthrough_token_params ~w(grant_type code redirect_uri code_verifier refresh_token client_id)

  @spec authorize(Plug.Conn.t()) :: Plug.Conn.t()
  def authorize(conn) do
    with {:ok, _idp} <- idp(),
         {:ok, upstream} <- KeyStore.fetch_endpoint("authorization_endpoint") do
      conn = fetch_query_params(conn)
      params = build_authorize_params(conn.query_params)
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
    with {:ok, idp} <- idp(),
         {:ok, upstream} <- KeyStore.fetch_endpoint("token_endpoint") do
      params = build_token_params(conn.body_params || %{}, idp)

      case Req.post(req(), url: upstream, form: params) do
        {:ok, %Req.Response{status: status, body: body}} ->
          {ct, body_iodata} = render_body(maybe_swap_for_id_token(body))

          conn
          |> put_resp_content_type(ct)
          |> send_resp(status, body_iodata)

        {:error, reason} ->
          send_broker_error(conn, "upstream_unreachable", reason)
      end
    else
      {:error, reason} -> send_broker_error(conn, "token_failed", reason)
    end
  end

  defp idp do
    case Application.get_env(:sark, :idp) do
      %IdP{} = idp -> {:ok, idp}
      _ -> {:error, :no_idp}
    end
  end

  # Inject scope only if the client didn't supply one. Drop anything not
  # on the passthrough list so the redirect to upstream stays minimal.
  defp build_authorize_params(query) do
    base =
      Enum.reduce(@passthrough_authorize_params, [], fn key, acc ->
        case Map.get(query, key) do
          v when is_binary(v) and v != "" -> [{key, v} | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    case Enum.find(base, fn {k, _} -> k == "scope" end) do
      nil -> base ++ [{"scope", @default_scope}]
      _ -> base
    end
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

  defp render_body(body) when is_binary(body), do: {"application/json", body}
  defp render_body(body) when is_map(body), do: {"application/json", Jason.encode!(body)}
  defp render_body(body), do: {"text/plain", inspect(body)}

  # Google (and possibly other IdPs) returns BOTH `access_token` (opaque)
  # and `id_token` (JWT) in the OIDC response. Sark verifies JWTs, so
  # swap them: hand the id_token back as `access_token`. Detection =
  # check if the original access_token looks like a JWT (3 dot-separated
  # base64url segments). If it does, no swap needed (Okta/Auth0 issue
  # JWT access tokens directly).
  defp maybe_swap_for_id_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded |> maybe_swap_for_id_token() |> Jason.encode!()
      _ -> body
    end
  end

  defp maybe_swap_for_id_token(%{"access_token" => access, "id_token" => id_token} = body)
       when is_binary(access) and is_binary(id_token) do
    if jwt_shaped?(access), do: body, else: Map.put(body, "access_token", id_token)
  end

  defp maybe_swap_for_id_token(body), do: body

  defp jwt_shaped?(token) do
    case String.split(token, ".") do
      [_, _, _] -> true
      _ -> false
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

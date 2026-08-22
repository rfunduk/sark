defmodule Sark.OAuth.Refresh do
  @moduledoc """
  In-band JIT refresh of sark sessions.

  Called by `Sark.AuthPlug.resolve_session/2`. Decides whether the
  session row needs an upstream refresh and, if so, runs the
  `grant_type=refresh_token` dance against the IdP. On success, the
  row is touched (new `expires_at`, possibly new `upstream_refresh`,
  claims usually unchanged because Google et al. don't reissue
  id_token on refresh — we keep the cached envelope).

  On failure (refresh_token revoked, network down, etc.) the session
  is deleted and `{:error, :revoked}` returned so AuthPlug can 401 the
  caller and trigger a fresh OAuth dance.
  """

  require Logger

  alias Sark.Auth.JWT
  alias Sark.Auth.KeyStore
  alias Sark.Auth.Session
  alias Sark.Config.IdP

  # Refresh when the session is within this many seconds of expiring.
  @refresh_buffer_seconds 300

  @doc """
  Returns the (possibly refreshed) session row. `:revoked` if upstream
  refused the refresh and the session row was dropped. `{:error, _}` for
  transient issues (network, malformed response) — caller should treat
  as 401 but the session row is preserved.
  """
  @spec maybe_refresh(String.t(), map, IdP.t() | nil) ::
          {:ok, map} | {:error, :revoked | term}
  def maybe_refresh(_plugin, row, nil), do: {:ok, row}

  def maybe_refresh(plugin, row, %IdP{} = idp) do
    if needs_refresh?(row), do: locked_refresh(plugin, row, idp), else: {:ok, row}
  end

  # Single-flight per session token. MCP clients fire concurrent
  # requests; without this, every request in the refresh window runs
  # its own upstream exchange with the same refresh token. Under
  # IdP-side refresh-token rotation the losers get `invalid_grant`,
  # which the 4xx branch below reads as revocation — deleting the
  # session the winner just refreshed (and reuse detection can revoke
  # the whole token family upstream). Waiters re-read the row inside
  # the lock and skip the upstream call when the winner already
  # extended it.
  defp locked_refresh(plugin, %{"token" => token}, idp) do
    :global.trans({{__MODULE__, plugin, token}, self()}, fn ->
      case Session.lookup(plugin, token) do
        {:ok, row} ->
          if needs_refresh?(row), do: do_refresh(plugin, row, idp), else: {:ok, row}

        # Deleted while we waited — a concurrent loser can no longer do
        # this, but an explicit logout/prune can.
        :not_found ->
          {:error, :revoked}

        {:error, _} = err ->
          err
      end
    end)
  end

  defp needs_refresh?(%{"expires_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        DateTime.diff(dt, DateTime.utc_now(), :second) < @refresh_buffer_seconds

      _ ->
        true
    end
  end

  defp needs_refresh?(_), do: true

  defp do_refresh(_plugin, %{"upstream_refresh" => nil}, _idp) do
    {:error, :no_refresh_token}
  end

  defp do_refresh(_plugin, %{"upstream_refresh" => ""}, _idp) do
    {:error, :no_refresh_token}
  end

  defp do_refresh(plugin, %{"upstream_refresh" => refresh, "token" => token} = row, idp) do
    with {:ok, upstream_url} <- KeyStore.fetch_endpoint("token_endpoint"),
         {:ok, body} <- post_refresh(upstream_url, refresh, idp),
         {:ok, claims} <- merge_claims(row, body, idp) do
      new_refresh = Map.get(body, "refresh_token", refresh)
      new_expires_at = compute_expiry(body)

      :ok =
        Session.touch(plugin, token,
          expires_at: new_expires_at,
          claims: claims,
          upstream_refresh: new_refresh
        )

      Logger.info(
        "auth: session #{mask(token)} refreshed (idle=#{idle_for(row)} " <>
          "rotated=#{new_refresh != refresh} next_expiry=#{DateTime.to_iso8601(new_expires_at)})"
      )

      refreshed_row =
        row
        |> Map.put("claims", claims)
        |> Map.put("expires_at", DateTime.to_iso8601(new_expires_at))
        |> Map.put("upstream_refresh", new_refresh)

      {:ok, refreshed_row}
    else
      {:error, {:upstream_4xx, status, body}} when status in 400..401 ->
        # Google / Okta return 400 or 401 when refresh_token is
        # invalid / revoked. Drop the session — caller must redo OAuth.
        # The body's `error` code matters operationally: `invalid_grant`
        # = the refresh token itself was refused (revoked/expired/
        # rotated), `invalid_client` = our credentials/auth-method were
        # refused — so it's logged, not discarded.
        Logger.info(
          "auth: session #{mask(token)} refresh rejected by IdP " <>
            "(status=#{status} body=#{inspect(body, limit: 10, printable_limit: 300)} " <>
            "created=#{row["created_at"]} last_refreshed=#{row["last_refreshed_at"]}); dropping"
        )

        _ = Session.delete(plugin, token)
        {:error, :revoked}

      {:error, reason} ->
        Logger.warning("auth: session refresh failed — #{inspect(reason)}; session preserved")
        {:error, reason}
    end
  end

  # Client credentials via HTTP Basic (`client_secret_basic`), matching
  # the broker's authorization_code exchange — Okta rejects secret-in-body
  # (`invalid_client`, HTTP 401) when the app is configured for Basic,
  # which this path's 400..401 branch then misread as a revoked refresh
  # token and dropped the session. No secret (public client) → client_id
  # in the form.
  defp post_refresh(url, refresh_token, %IdP{client_id: client_id, client_secret: secret}) do
    form = [
      {"grant_type", "refresh_token"},
      {"refresh_token", refresh_token}
    ]

    {form, req_opts} =
      if is_binary(secret) and secret != "" do
        {form, [auth: {:basic, client_id <> ":" <> secret}]}
      else
        {add_param(form, "client_id", client_id), []}
      end

    case Req.post(req(), [url: url, form: form] ++ req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, decode_body(body)}

      {:ok, %Req.Response{status: status, body: body}} when status in 400..499 ->
        {:error, {:upstream_4xx, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:upstream, status, body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp add_param(list, _key, nil), do: list
  defp add_param(list, _key, ""), do: list
  defp add_param(list, key, value), do: list ++ [{key, value}]

  # If upstream reissues id_token (Okta/Auth0 sometimes do), re-verify
  # it. If absent (Google's normal refresh behavior), keep cached
  # claims unchanged.
  defp merge_claims(%{"claims" => existing}, %{"id_token" => id_token}, %IdP{} = idp)
       when is_binary(id_token) do
    case JWT.verify(id_token, idp) do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} -> {:ok, existing}
    end
  end

  defp merge_claims(%{"claims" => existing}, _, _), do: {:ok, existing}

  defp compute_expiry(%{"expires_in" => secs}) when is_integer(secs) and secs > 0 do
    DateTime.utc_now() |> DateTime.add(secs, :second)
  end

  defp compute_expiry(_), do: DateTime.utc_now() |> DateTime.add(3600, :second)

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp req do
    case Application.get_env(:sark, :req_plug) do
      nil -> Req.new()
      plug -> Req.new(plug: plug)
    end
  end

  defp mask(token) when is_binary(token), do: String.slice(token, 0, 12) <> "…"

  defp idle_for(%{"last_refreshed_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> "#{DateTime.diff(DateTime.utc_now(), dt, :second)}s"
      _ -> "?"
    end
  end

  defp idle_for(_), do: "?"
end

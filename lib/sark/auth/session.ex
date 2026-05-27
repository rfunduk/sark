defmodule Sark.Auth.Session do
  @moduledoc """
  Per-plugin OAuth session store. Backed by `_sessions` table in each
  plugin's `<plugin>.sark.db`.

  A session abstracts away upstream JWT lifecycle: sark holds the
  upstream refresh token + caches the last-known identity claims.
  Clients hold an opaque `sk-sark-<random>` and never see upstream
  tokens. This isolates Google's quirks (no id_token reissue on
  refresh, opaque access tokens) from sark's verification model.
  """

  alias Sark.Plugin.DB

  @session_prefix "sk-sark-"
  # 32 url-safe base64 chars ≈ 192 bits of entropy.
  @rand_bytes 24

  @doc """
  Create a session row. Returns the generated `sk-sark-*` token.
  """
  @spec create(String.t(), map, String.t() | nil, DateTime.t()) ::
          {:ok, String.t()} | {:error, term}
  def create(plugin, claims, upstream_refresh, %DateTime{} = expires_at) when is_map(claims) do
    token = @session_prefix <> rand_token()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    INSERT INTO _sessions (
      token, upstream_refresh, claims_json,
      created_at, last_refreshed_at, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    """

    params = [
      token,
      upstream_refresh,
      Jason.encode!(claims),
      now,
      now,
      DateTime.to_iso8601(expires_at)
    ]

    case DB.sark_write(plugin, sql, params) do
      {:ok, _} -> {:ok, token}
      {:error, _} = err -> err
    end
  end

  @doc """
  Look up a session by token. Returns the full row map or `:not_found`.
  Claims are decoded into a map; `expires_at` is left as ISO-8601 string
  (callers compare via `DateTime.from_iso8601/1`).
  """
  @spec lookup(String.t(), String.t()) :: {:ok, map} | :not_found | {:error, term}
  def lookup(plugin, token) when is_binary(token) do
    sql = "SELECT * FROM _sessions WHERE token = ? LIMIT 1"

    case DB.sark_read(plugin, sql, [token]) do
      {:ok, _cols, []} ->
        :not_found

      {:ok, _cols, [row]} ->
        # `claims_json` round-trips through sark's `DB.rows_to_maps`
        # auto-JSON-decode hook, so by the time it reaches us it's
        # already a map.
        {:ok, Map.put(row, "claims", row["claims_json"])}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Touch a session after a successful upstream refresh. Updates
  `last_refreshed_at` + `expires_at`; optionally replaces claims +
  `upstream_refresh` if the IdP issued new ones.
  """
  @spec touch(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def touch(plugin, token, opts) do
    expires_at =
      opts
      |> Keyword.fetch!(:expires_at)
      |> DateTime.to_iso8601()

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    {sets, binds} = build_touch_updates(opts)

    sql =
      "UPDATE _sessions SET last_refreshed_at = ?, expires_at = ?#{sets} WHERE token = ?"

    case DB.sark_write(plugin, sql, [now, expires_at | binds] ++ [token]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Drop a session (e.g. on refresh failure or explicit logout)."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term}
  def delete(plugin, token) do
    case DB.sark_write(plugin, "DELETE FROM _sessions WHERE token = ?", [token]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "True iff `token` has the sark-session shape."
  @spec session_token?(String.t()) :: boolean
  def session_token?(@session_prefix <> _), do: true
  def session_token?(_), do: false

  defp build_touch_updates(opts) do
    Enum.reduce(opts, {"", []}, fn
      {:claims, claims}, {sql, binds} when is_map(claims) ->
        {sql <> ", claims_json = ?", binds ++ [Jason.encode!(claims)]}

      {:upstream_refresh, new}, {sql, binds} when is_binary(new) ->
        {sql <> ", upstream_refresh = ?", binds ++ [new]}

      {:upstream_refresh, nil}, acc ->
        acc

      {:expires_at, _}, acc ->
        acc

      _, acc ->
        acc
    end)
  end

  defp rand_token, do: :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
end

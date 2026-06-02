defmodule Sark.OAuth.Correlator do
  @moduledoc """
  Short-TTL key→value store bridging the broker's redirect-uri dance.

  Sark is a full OAuth broker: it terminates the upstream callback at its
  own fixed `/oauth/callback` and re-issues to the downstream client's
  (random) localhost port. Two correlations span the request gaps:

    * `state:<sark_state>` → authorize context, stashed on `/authorize`,
      popped on `/oauth/callback`. Holds the downstream client's
      redirect_uri / state / PKCE challenge + the target plugin. ~5min
      TTL (covers the interactive login).

    * `code:<sark_code>` → token context, stashed on `/oauth/callback`,
      popped on `/oauth/token`. Holds the upstream auth code + the
      downstream PKCE challenge + plugin. ~60s TTL (machine-to-machine
      code exchange happens immediately).

  In-memory ETS, single-node. Expiry enforced at `pop/1` (the security
  boundary — an expired entry is never exchangeable); abandoned entries
  linger until VM restart, which is harmless given they can't be popped.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Stash `value` under `key` for `ttl_ms` milliseconds."
  @spec stash(String.t(), term(), pos_integer()) :: :ok
  def stash(key, value, ttl_ms) when is_binary(key) and is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc """
  Atomically remove + return the value for `key`. Single-use: a key can
  be popped at most once. Returns `:not_found` for unknown or expired
  keys (expired entries are deleted on the way out).
  """
  @spec pop(String.t()) :: {:ok, term()} | :not_found
  def pop(key) when is_binary(key) do
    case :ets.take(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) <= expires_at do
          {:ok, value}
        else
          :not_found
        end

      [] ->
        :not_found
    end
  end
end

defmodule Sark.OAuth.Correlator do
  @moduledoc """
  Bridges the OAuth `/authorize` → `/token` request gap with PKCE.

  At `/authorize` we know the plugin (parsed from RFC 8707 `resource=`
  param) and the client's `code_challenge`. At `/token`, the client
  sends `code_verifier` instead — sark computes `S256(code_verifier)`
  to derive the original challenge and recover the plugin.

  In-memory ETS table; TTL'd by the natural shape of an auth-code flow
  (clients exchange within seconds of authorize). Entries get explicitly
  forgotten after the token exchange — no GC needed for the happy path.
  Abandoned entries linger until VM restart; not worth a sweeper for
  now.
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

  @doc """
  Stash `code_challenge → plugin` for later lookup.
  """
  @spec stash(String.t(), String.t()) :: :ok
  def stash(code_challenge, plugin)
      when is_binary(code_challenge) and is_binary(plugin) do
    :ets.insert(@table, {code_challenge, plugin})
    :ok
  end

  @doc """
  Look up the plugin associated with a `code_verifier` by computing
  `S256(verifier)` and matching against stashed challenges.
  """
  @spec lookup(String.t()) :: {:ok, String.t()} | :not_found
  def lookup(code_verifier) when is_binary(code_verifier) do
    challenge = challenge_from_verifier(code_verifier)

    case :ets.lookup(@table, challenge) do
      [{^challenge, plugin}] -> {:ok, plugin}
      [] -> :not_found
    end
  end

  @doc "Drop a stashed entry — call after a successful token exchange."
  @spec forget(String.t()) :: :ok
  def forget(code_verifier) when is_binary(code_verifier) do
    :ets.delete(@table, challenge_from_verifier(code_verifier))
    :ok
  end

  defp challenge_from_verifier(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end
end

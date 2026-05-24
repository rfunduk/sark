defmodule Sark.Embedder.Cache do
  @moduledoc """
  Small LRU/TTL cache for query-embedding results, keyed by
  `(model, sha256(text))` → `binary vector`. Public ETS table,
  created lazily on first use. No GenServer — every op is a single
  ETS call, safe across the BEAM.

  `vec_search`-style tools embed the same query text repeatedly in
  tight loops (re-render, pagination, A/B); the cache eats those
  repeat calls so the embedder API isn't billed.

  Sizing: cache size capped at `@max_entries`. When an insert would
  exceed it, the oldest @prune_batch entries get dropped in one
  `:ets.select_delete/2` pass. Keeps the cache bounded without a
  per-op LRU bookkeep.

  TTL: each entry has an absolute expiration; reads past expiration
  return `:miss`. Default 5 minutes.
  """

  @table __MODULE__
  @default_ttl_ms 5 * 60 * 1_000
  @max_entries 1_024
  @prune_batch 128

  @doc """
  Look up a cached vector. Returns `{:ok, binary}` (the same form
  passed to `insert/3`) or `:miss`.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, binary()} | :miss
  def lookup(model, text) when is_binary(model) and is_binary(text) do
    ensure_table()
    now = monotonic_ms()

    case :ets.lookup(@table, key(model, text)) do
      [{_, vec, exp}] when exp > now -> {:ok, vec}
      _ -> :miss
    end
  end

  @doc """
  Cache a vector for `(model, text)`. `ttl_ms` overrides the default
  if given.
  """
  @spec insert(String.t(), String.t(), binary(), keyword()) :: :ok
  def insert(model, text, vec, opts \\ [])
      when is_binary(model) and is_binary(text) and is_binary(vec) do
    ensure_table()
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    exp = monotonic_ms() + ttl

    :ets.insert(@table, {key(model, text), vec, exp})
    maybe_prune()

    :ok
  end

  @doc "Drop all entries. For tests."
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Current entry count. For tests + telemetry."
  @spec size() :: non_neg_integer()
  def size do
    ensure_table()
    :ets.info(@table, :size) || 0
  end

  # ── internals ────────────────────────────────────────────────────────

  defp key(model, text) do
    {model, :crypto.hash(:sha256, text)}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp maybe_prune do
    if :ets.info(@table, :size) > @max_entries do
      prune_oldest(@prune_batch)
    end

    :ok
  end

  defp prune_oldest(n) do
    # Match-spec: select all entries, sorted by ascending exp. Then
    # delete the lowest n. Simpler than maintaining an explicit LRU
    # list at the cost of an O(N) pass on overflow.
    all =
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_k, _v, exp} -> exp end)
      |> Enum.take(n)

    Enum.each(all, fn {k, _, _} -> :ets.delete(@table, k) end)
  end
end

defmodule Sark.AuthRegistry do
  @moduledoc """
  ETS-backed token → entry lookup.

  Init from `Sark.Config.tokens` (`%{token => %{name:, allowed:}}`).
  Read path is lock-free; lookup cost is constant. Logs reference the
  operator name, never the token.

  `entry.allowed` is `:all | %{plugin => :all | [block]}` where `block`
  is `%{pos: [Regex], neg: [Regex]}`. A plugin key present at all = the
  token can reach `/<plugin>/mcp`. Value `:all` = unrestricted surface;
  list of blocks = each block contributes names whose pos matches AND
  no neg matches. Cross-block union (names granted by *any* block).
  Resolved per-connection in the router's `connect/2` and stored as
  `Phantom.Session.allowed_tools`.
  """

  use GenServer

  @table __MODULE__

  @type block :: %{pos: [Regex.t()], neg: [Regex.t()]}
  @type tool_grant :: :all | [block()]
  @type allowed :: :all | %{String.t() => tool_grant()}
  @type entry :: %{name: String.t(), allowed: allowed()}

  @spec start_link(%{String.t() => entry()}) :: GenServer.on_start()
  def start_link(tokens) when is_map(tokens) do
    GenServer.start_link(__MODULE__, tokens, name: __MODULE__)
  end

  @spec lookup(String.t()) :: {:ok, entry()} | :error
  def lookup(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  @spec authorized?(entry(), String.t()) :: boolean()
  def authorized?(%{allowed: :all}, plugin) when is_binary(plugin), do: true

  def authorized?(%{allowed: allowed}, plugin) when is_map(allowed) and is_binary(plugin),
    do: Map.has_key?(allowed, plugin)

  @doc """
  Resolve the token's tool-name allow-list for `plugin` against the set
  of tool names actually registered for that plugin.

  Returns `:all` when the token has unrestricted access to the plugin
  (caller should leave `session.allowed_tools` as `nil`, i.e. no filter).
  Otherwise returns the filtered subset of `available` matching the
  token's compiled glob patterns. An empty list means the token can
  reach the plugin but no tools match — every call will be rejected.
  """
  @spec tool_allowlist(entry(), String.t(), [String.t()]) :: :all | [String.t()]
  def tool_allowlist(%{allowed: :all}, plugin, available)
      when is_binary(plugin) and is_list(available),
      do: :all

  def tool_allowlist(%{allowed: allowed}, plugin, available)
      when is_map(allowed) and is_binary(plugin) and is_list(available) do
    case Map.get(allowed, plugin) do
      nil -> []
      :all -> :all
      blocks when is_list(blocks) -> Enum.filter(available, &any_block_grants?(blocks, &1))
    end
  end

  defp any_block_grants?(blocks, name),
    do: Enum.any?(blocks, &block_grants?(&1, name))

  defp block_grants?(%{pos: pos, neg: neg}, name) do
    Enum.any?(pos, &Regex.match?(&1, name)) and
      not Enum.any?(neg, &Regex.match?(&1, name))
  end

  @impl true
  def init(tokens) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Enum.each(tokens, fn {tok, entry} -> :ets.insert(@table, {tok, entry}) end)
    {:ok, %{}}
  end
end

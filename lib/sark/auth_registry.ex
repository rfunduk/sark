defmodule Sark.AuthRegistry do
  @moduledoc """
  ETS-backed token → `{name, allowed_plugins}` lookup.

  Init from `Sark.Config.tokens` (`%{token => %{name:, allowed:}}`).
  Read path is lock-free; lookup cost is constant. Logs reference the
  operator name, never the token.

  `allowed` is `:all` (wildcard) or a `MapSet` of plugin names. The
  endpoint scopes each request to a single plugin via the URL
  (`/<plugin>/mcp`); use `authorized?/2` to check.
  """

  use GenServer

  @table __MODULE__

  @type entry :: %{name: String.t(), allowed: :all | MapSet.t(String.t())}

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

  def authorized?(%{allowed: %MapSet{} = set}, plugin) when is_binary(plugin),
    do: MapSet.member?(set, plugin)

  @impl true
  def init(tokens) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Enum.each(tokens, fn {tok, entry} -> :ets.insert(@table, {tok, entry}) end)
    {:ok, %{}}
  end
end

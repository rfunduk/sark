defmodule Sark.AuthRegistry do
  @moduledoc """
  ETS-backed token → operator-name lookup.

  Init from `Sark.Config` tokens map. Read path is lock-free; lookup
  cost is constant. Logs reference the operator name, never the token.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(%{String.t() => String.t()}) :: GenServer.on_start()
  def start_link(tokens) when is_map(tokens) do
    GenServer.start_link(__MODULE__, tokens, name: __MODULE__)
  end

  @spec lookup(String.t()) :: {:ok, String.t()} | :error
  def lookup(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, name}] -> {:ok, name}
      [] -> :error
    end
  end

  @impl true
  def init(tokens) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Enum.each(tokens, fn {tok, name} -> :ets.insert(@table, {tok, name}) end)
    {:ok, %{}}
  end
end

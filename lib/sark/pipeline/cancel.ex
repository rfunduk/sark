defmodule Sark.Pipeline.Cancel do
  @moduledoc """
  Best-effort cancel flag store for in-flight pipeline runs.

  `request/1` sets a flag against a `run_id`. The runner peeks the
  flag between steps (`requested?/1`) and between LLM turns; on a hit,
  the current step finishes naturally and the run is marked
  `cancelled`. No mid-step interrupt, no SIGTERM gymnastics — a shell
  step blocked on a 10-minute curl will block the cancel for up to
  10 minutes (use `timeout:` to bound it).

  In-memory only. Sark restart drops both the in-flight run (its Task
  dies) and the flag, which is consistent.
  """

  use GenServer

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Request cancellation of `run_id`."
  @spec request(String.t()) :: :ok
  def request(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:request, run_id})
  end

  @doc "True if `run_id` has a pending cancel."
  @spec requested?(String.t()) :: boolean
  def requested?(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:requested?, run_id})
  end

  @doc """
  Clear the cancel flag for `run_id`. Idempotent — clearing a flag
  that isn't set is a no-op. The runner calls this in a `try .. after`
  so flags don't leak after terminal state.
  """
  @spec clear(String.t()) :: :ok
  def clear(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:clear, run_id})
  end

  @doc false
  def pending, do: GenServer.call(__MODULE__, :pending)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:request, id}, _from, set),
    do: {:reply, :ok, MapSet.put(set, id)}

  @impl true
  def handle_call({:requested?, id}, _from, set),
    do: {:reply, MapSet.member?(set, id), set}

  @impl true
  def handle_call({:clear, id}, _from, set),
    do: {:reply, :ok, MapSet.delete(set, id)}

  @impl true
  def handle_call(:pending, _from, set),
    do: {:reply, MapSet.to_list(set), set}
end

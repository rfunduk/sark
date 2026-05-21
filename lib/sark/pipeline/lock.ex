defmodule Sark.Pipeline.Lock do
  @moduledoc """
  Singleton GenServer tracking in-flight pipeline runs.

  One slot per `{plugin, pipeline_name}`. `acquire/3` claims the slot
  atomically; `release/2` (or task DOWN) frees it. Used by both the
  scheduler (cron) and manual triggers (mix task, future MCP run_now)
  so the lock arbitrates across all entry points.

  Crash-safe: the caller process must `register_run/3` after the run
  spawns, passing the run pid; the Lock monitors that pid and releases
  on DOWN. This avoids leaking a slot when a pipeline task crashes
  before reaching its `release/2`.
  """

  use GenServer

  @type plugin :: String.t()
  @type pipeline_name :: atom

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Attempt to claim the slot for `{plugin, pipeline_name}`.

  Returns `{:ok, run_id}` on success — caller now owns the slot and
  must follow up with `register_run/3` once the run pid is known
  (single message between calls; no other process can claim in the
  gap because we're a GenServer).

  Returns `{:busy, existing_run_id}` if a run is already in flight.
  """
  @spec acquire(plugin, pipeline_name) :: {:ok, String.t()} | {:busy, String.t()}
  def acquire(plugin, pipeline_name)
      when is_binary(plugin) and is_atom(pipeline_name) do
    GenServer.call(__MODULE__, {:acquire, plugin, pipeline_name})
  end

  @doc """
  Attach a monitored pid to an acquired slot. Lock releases automatically
  if the pid dies.
  """
  @spec register_run(plugin, pipeline_name, pid) :: :ok
  def register_run(plugin, pipeline_name, pid)
      when is_binary(plugin) and is_atom(pipeline_name) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_run, plugin, pipeline_name, pid})
  end

  @doc """
  Release the slot. Idempotent — releasing a slot that isn't held is a
  no-op (lets runners call this in a `try .. after` without checking).
  """
  @spec release(plugin, pipeline_name) :: :ok
  def release(plugin, pipeline_name)
      when is_binary(plugin) and is_atom(pipeline_name) do
    GenServer.call(__MODULE__, {:release, plugin, pipeline_name})
  end

  @doc """
  Snapshot of every in-flight slot — `[{plugin, pipeline_name, run_id}, ...]`.
  Used by tests and (eventually) `sark_pipelines_list`.
  """
  @spec in_flight() :: [{plugin, pipeline_name, String.t()}]
  def in_flight do
    GenServer.call(__MODULE__, :in_flight)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    # State: %{{plugin, name} => %{run_id, pid_ref}}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, plugin, name}, _from, state) do
    key = {plugin, name}

    case Map.fetch(state, key) do
      :error ->
        run_id = new_run_id()
        {:reply, {:ok, run_id}, Map.put(state, key, %{run_id: run_id, pid_ref: nil})}

      {:ok, %{run_id: existing}} ->
        {:reply, {:busy, existing}, state}
    end
  end

  @impl true
  def handle_call({:register_run, plugin, name, pid}, _from, state) do
    key = {plugin, name}

    case Map.fetch(state, key) do
      {:ok, entry} ->
        ref = Process.monitor(pid)
        {:reply, :ok, Map.put(state, key, %{entry | pid_ref: ref})}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release, plugin, name}, _from, state) do
    key = {plugin, name}

    state =
      case Map.fetch(state, key) do
        {:ok, %{pid_ref: ref}} when is_reference(ref) ->
          Process.demonitor(ref, [:flush])
          Map.delete(state, key)

        {:ok, _} ->
          Map.delete(state, key)

        :error ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:in_flight, _from, state) do
    list =
      Enum.map(state, fn {{plugin, name}, %{run_id: id}} ->
        {plugin, name, id}
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      state
      |> Enum.reject(fn {_, %{pid_ref: r}} -> r == ref end)
      |> Map.new()

    {:noreply, state}
  end

  # 16-hex run id. Plenty for log keys; not UUIDs because no need to drag
  # in a UUID dep.
  defp new_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

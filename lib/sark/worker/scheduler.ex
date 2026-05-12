defmodule Sark.Worker.Scheduler do
  @moduledoc """
  Per-plugin cron scheduler for workers.

  Ticks every minute. On each tick, walks the plugin's workers; if a
  worker's `schedule:` cron matches the current minute *and* a previous
  run isn't still in flight, spawns a `Task` running
  `Sark.Worker.Runner.run/1`.

  Concurrency: at most one in-flight run per worker. If the previous
  run is still going when the next tick fires, the tick is skipped (a
  warning is logged). Workers are idempotent — `when:` gates are
  re-evaluated each run, so a missed tick just means "nothing happened
  this minute".

  Crashes: a worker Task crash is isolated; the scheduler keeps ticking.

  Manual trigger via `mix sark.worker` is unaffected — it builds a
  short-lived runner inline, doesn't talk to the scheduler.
  """

  use GenServer
  require Logger

  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker
  alias Sark.Worker.LLM.Anthropix
  alias Sark.Worker.Runner

  # Tick at second 0 of every minute (drifts <1s).
  @tick_interval_ms 60_000

  @type opts :: [spec: Spec.t()]

  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts) do
    %Spec{} = spec = Keyword.fetch!(opts, :spec)
    GenServer.start_link(__MODULE__, spec, name: registered_name(spec.name))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin_name), do: :"sark_scheduler_#{plugin_name}"

  @doc """
  Replace the spec backing a running scheduler. Used by the hot-reload
  watcher: after `workers.yml` changes, the loader rebuilds `spec` and
  pushes it here. In-flight tasks are not interrupted.
  """
  @spec update_spec(String.t(), Spec.t()) :: :ok
  def update_spec(plugin_name, %Spec{} = spec) do
    case Process.whereis(registered_name(plugin_name)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:update_spec, spec})
    end
  end

  @impl true
  def init(%Spec{} = spec) do
    scheduled = Enum.filter(spec.workers || [], & &1.schedule)

    if scheduled != [] do
      Logger.info(
        "scheduler #{spec.name} — #{length(scheduled)} worker(s) scheduled: " <>
          Enum.map_join(scheduled, ", ", &Atom.to_string(&1.name))
      )
    end

    schedule_next_tick()

    {:ok,
     %{
       spec: spec,
       scheduled: scheduled,
       in_flight: %{}
     }}
  end

  @impl true
  def handle_cast({:update_spec, %Spec{} = spec}, state) do
    scheduled = Enum.filter(spec.workers || [], & &1.schedule)
    old_names = state.scheduled |> Enum.map(& &1.name) |> MapSet.new()
    new_names = scheduled |> Enum.map(& &1.name) |> MapSet.new()

    added = MapSet.difference(new_names, old_names) |> MapSet.to_list()
    removed = MapSet.difference(old_names, new_names) |> MapSet.to_list()

    if added != [] or removed != [] do
      Logger.info(
        "scheduler #{spec.name} — reloaded; " <>
          "+#{inspect(added)} -#{inspect(removed)} (total #{length(scheduled)})"
      )
    end

    {:noreply, %{state | spec: spec, scheduled: scheduled}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now() |> DateTime.to_naive() |> truncate_to_minute()

    state =
      Enum.reduce(state.scheduled, state, fn %Worker{} = worker, acc ->
        cond do
          not matches?(worker.schedule, now) ->
            acc

          Map.has_key?(acc.in_flight, worker.name) ->
            Logger.warning(
              "scheduler #{state.spec.name}.#{worker.name} — previous run still in flight, skipping tick"
            )

            acc

          true ->
            spawn_run(state.spec, worker, acc)
        end
      end)

    schedule_next_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, drop_in_flight(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason != :normal do
      case Map.get(state.in_flight, ref_to_name(state, ref)) do
        nil ->
          :ok

        name ->
          Logger.error("scheduler #{state.spec.name}.#{name} — task crashed: #{inspect(reason)}")
      end
    end

    {:noreply, drop_in_flight(state, ref)}
  end

  @doc false
  def matches?(%Crontab.CronExpression{} = cron, %NaiveDateTime{} = now) do
    Crontab.DateChecker.matches_date?(cron, now)
  end

  defp truncate_to_minute(%NaiveDateTime{} = ndt) do
    %{ndt | second: 0, microsecond: {0, 0}}
  end

  defp schedule_next_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp spawn_run(%Spec{} = spec, %Worker{} = worker, state) do
    plugin = spec.name

    task =
      Task.Supervisor.async_nolink(Sark.Worker.TaskSup, fn ->
        Logger.info("scheduler #{plugin}.#{worker.name} — firing")

        try do
          Runner.run(plugin: plugin, worker: worker, spec: spec, llm: Anthropix)
        rescue
          e ->
            Logger.error(
              "scheduler #{plugin}.#{worker.name} — runner raised: #{Exception.message(e)}"
            )

            {:error, e}
        end
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, worker.name)}
  end

  defp drop_in_flight(state, ref) do
    %{state | in_flight: Map.delete(state.in_flight, ref)}
  end

  defp ref_to_name(state, ref), do: Map.get(state.in_flight, ref)
end

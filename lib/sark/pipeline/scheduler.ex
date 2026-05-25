defmodule Sark.Pipeline.Scheduler do
  @moduledoc """
  Per-plugin cron scheduler for pipelines.

  Ticks every minute. On each tick, walks the plugin's pipelines; if a
  pipeline has a `schedule:` cron that matches the current minute and
  the per-pipeline lock can be acquired, spawns a `Task` running
  `Sark.Pipeline.Runner.run/1`.

  Concurrency arbitration lives in `Sark.Pipeline.Lock` so that the
  scheduler + manual triggers (mix task, future MCP `run_now`) all
  share one source of truth. A cron fire that collides with an
  in-flight run is dropped with a warning — same posture as the
  legacy worker scheduler.

  Pipelines without a `schedule:` (manual-only) are ignored here.

  Crash isolation: pipeline tasks run under `Sark.Pipeline.TaskSup`,
  not as scheduler children. A pipeline crash logs and frees the lock
  (via the Lock's pid monitor) without taking the scheduler down.
  """

  use GenServer
  require Logger

  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec
  alias Sark.Pipeline.Lock
  alias Sark.Pipeline.State
  alias Sark.Pipeline.Watcher

  @tick_interval_ms 60_000

  @type opts :: [spec: Spec.t()]

  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts) do
    %Spec{} = spec = Keyword.fetch!(opts, :spec)
    GenServer.start_link(__MODULE__, spec, name: registered_name(spec.name))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin_name), do: :"sark_pipeline_scheduler_#{plugin_name}"

  @impl true
  def init(%Spec{} = spec) do
    scheduled = Enum.filter(spec.pipelines || [], & &1.schedule)

    if scheduled != [] do
      Logger.info(
        "pipeline scheduler #{spec.name} — #{length(scheduled)} pipeline(s) scheduled: " <>
          Enum.map_join(scheduled, ", ", &Atom.to_string(&1.name))
      )
    end

    schedule_next_tick()

    {:ok,
     %{
       spec: spec,
       scheduled: scheduled
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now() |> DateTime.to_naive() |> truncate_to_minute()

    Enum.each(state.scheduled, fn %Pipeline{} = pipeline ->
      cond do
        not matches?(pipeline.schedule, now) ->
          :ok

        State.disabled?(state.spec.name, pipeline.name) ->
          # Silent skip — no log row, matches `when:`-gated skip posture.
          :ok

        true ->
          attempt_fire(state.spec, pipeline)
      end
    end)

    schedule_next_tick()
    {:noreply, state}
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

  # Acquire-then-spawn. Lock arbitrates between cron and manual triggers.
  defp attempt_fire(%Spec{} = spec, %Pipeline{} = pipeline) do
    case Lock.acquire(spec.name, pipeline.name) do
      {:busy, existing_run_id} ->
        Logger.warning(
          "scheduler #{spec.name}.#{pipeline.name} — previous run #{existing_run_id} still in flight, skipping tick"
        )

      {:ok, run_id} ->
        spawn_run(spec, pipeline, run_id)
    end
  end

  defp spawn_run(%Spec{} = spec, %Pipeline{} = pipeline, run_id) do
    plugin = spec.name

    {:ok, pid} =
      Task.Supervisor.start_child(
        Sark.Pipeline.TaskSup,
        fn ->
          result =
            try do
              Watcher.run(
                plugin: plugin,
                pipeline: pipeline,
                spec: spec,
                run_id: run_id,
                llm: Sark.LLM.Anthropic,
                triggered_by: :schedule
              )
            rescue
              e ->
                Logger.error(
                  "scheduler #{plugin}.#{pipeline.name} — runner raised: #{Exception.message(e)}"
                )

                {:error, e}
            after
              Lock.release(plugin, pipeline.name)
            end

          log_outcome(plugin, pipeline.name, run_id, result)
        end,
        restart: :temporary
      )

    Lock.register_run(plugin, pipeline.name, pid)
  end

  defp log_outcome(plugin, name, run_id, {:ok, :skipped}) do
    Logger.debug("scheduler #{plugin}.#{name} — run #{run_id} skipped (when: gate)")
  end

  defp log_outcome(plugin, name, run_id, {:ok, _}) do
    Logger.info("scheduler #{plugin}.#{name} — run #{run_id} ok")
  end

  defp log_outcome(plugin, name, run_id, {:error, msg}) do
    Logger.warning("scheduler #{plugin}.#{name} — run #{run_id} failed: #{inspect(msg)}")
  end

  defp log_outcome(plugin, name, run_id, other) do
    Logger.warning(
      "scheduler #{plugin}.#{name} — run #{run_id} unexpected return: #{inspect(other)}"
    )
  end
end

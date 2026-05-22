defmodule Sark.Pipeline.Watcher do
  @moduledoc """
  Supervises one pipeline run with uniform best-effort kill semantics.

  Spawns the runner as a Task under `Sark.Pipeline.TaskSup` and yields
  on it with a deadline budget. Three triggers converge on the same
  `Task.shutdown(:brutal_kill)` path:

    * **pipeline timeout** — budget (`pipeline.timeout_ms`) exhausted
    * **cancel flag** (`Sark.Pipeline.Cancel.requested?/1`) — sets
      remaining budget to 0 on the next tick
    * **step timeout** — the runner self-exits with
      `{:step_timeout, idx}`; watcher sees `{:exit, _}` from
      `Task.yield`

  After the runner terminates by any path, the watcher writes the
  terminal `_pipeline_log` row via `LogWriter.finish_run/5` — this is
  the only place terminal rows are written. The cancel flag is
  cleared on the way out. The per-pipeline `Lock` slot is released
  via the Lock's own pid monitor on the runner task pid.

  Watcher.run/1 is synchronous from the caller's perspective: it
  blocks until the run terminates and returns the same result shape
  as `Runner.run/1` so existing call sites can adopt it as a drop-in
  replacement.
  """

  alias Sark.Pipeline.Cancel
  alias Sark.Pipeline.LogWriter
  alias Sark.Pipeline.Runner

  require Logger

  @yield_tick_ms 250

  @spec run(keyword) :: {:ok, %{run_id: String.t()}} | {:ok, :skipped} | {:error, term}
  def run(opts) do
    plugin = Keyword.fetch!(opts, :plugin)
    pipeline = Keyword.fetch!(opts, :pipeline)
    run_id = Keyword.fetch!(opts, :run_id)
    deadline = pipeline.timeout_ms || :infinity

    task =
      Task.Supervisor.async_nolink(Sark.Pipeline.TaskSup, fn ->
        Runner.run(opts)
      end)

    try do
      outcome = loop(task, deadline, run_id)
      finalize(plugin, run_id, outcome)
    after
      Cancel.clear(run_id)
    end
  end

  # ── yield loop ────────────────────────────────────────────────────────────

  defp loop(task, :infinity, run_id) do
    case Task.yield(task, @yield_tick_ms) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:exit, reason}

      nil ->
        if Cancel.requested?(run_id) do
          kill(task, :cancelled)
        else
          loop(task, :infinity, run_id)
        end
    end
  end

  defp loop(task, remaining, run_id) when is_integer(remaining) and remaining > 0 do
    tick = min(remaining, @yield_tick_ms)

    case Task.yield(task, tick) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:exit, reason}

      nil ->
        if Cancel.requested?(run_id) do
          kill(task, :cancelled)
        else
          loop(task, remaining - tick, run_id)
        end
    end
  end

  defp loop(task, _remaining_le_0, _run_id) do
    kill(task, :timed_out)
  end

  defp kill(task, reason_atom) do
    # brutal_kill: don't wait. Returns either {:ok, result} (raced finish),
    # {:exit, reason}, or nil. Treat all as the kill we intended.
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> {:kill, reason_atom}
    end
  end

  # ── finalize ─────────────────────────────────────────────────────────────

  defp finalize(_plugin, _run_id, {:ok, {:ok, :skipped}}) do
    {:ok, :skipped}
  end

  defp finalize(plugin, run_id, {:ok, {:ok, %{run_id: _} = ret}}) do
    :ok = LogWriter.finish_run(plugin, run_id, :success, now_iso8601(), nil)
    {:ok, ret}
  end

  defp finalize(plugin, run_id, {:ok, {:error, msg}}) when is_binary(msg) do
    :ok = LogWriter.finish_run(plugin, run_id, :failed, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:ok, {:error, reason}}) do
    msg = inspect(reason)
    :ok = LogWriter.finish_run(plugin, run_id, :failed, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:exit, {:step_timeout, idx}}) do
    msg = "step #{idx}: timeout"
    :ok = LogWriter.finish_run(plugin, run_id, :timed_out, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:exit, :killed}) do
    # Brutal-killed by something outside our loop. Treat as crashed.
    msg = "killed"
    :ok = LogWriter.finish_run(plugin, run_id, :crashed, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:exit, reason}) do
    msg = "crashed: #{inspect(reason)}"
    :ok = LogWriter.finish_run(plugin, run_id, :crashed, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:kill, :timed_out}) do
    msg = "pipeline timeout"
    :ok = LogWriter.finish_run(plugin, run_id, :timed_out, now_iso8601(), msg)
    {:error, msg}
  end

  defp finalize(plugin, run_id, {:kill, :cancelled}) do
    msg = "cancelled"
    :ok = LogWriter.finish_run(plugin, run_id, :cancelled, now_iso8601(), msg)
    {:error, msg}
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

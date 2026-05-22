defmodule Sark.Pipeline.LogWriter do
  @moduledoc """
  Per-plugin serializer for `_pipeline_log` + `_pipeline_step_log`
  writes. One process per plugin, supervised under `Sark.Plugin`.

  Runner casts in-flight events (`start_run`, `record_step`) so its
  own mid-step death doesn't lose an in-flight write — the cast lands
  in this process's mailbox before the runner dies, and this process
  survives to write it.

  Terminal `finish_run` is a sync call. The watcher above the runner
  is responsible for invoking it on both normal completion and
  abnormal `:DOWN`, so terminal status is durable regardless of how
  the run ends (success / failed / cancelled / timed_out / crashed).
  """

  use GenServer

  alias Sark.Pipeline.Log

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    plugin = Keyword.fetch!(opts, :plugin)
    GenServer.start_link(__MODULE__, plugin, name: registered_name(plugin))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin) when is_binary(plugin),
    do: :"sark_pipeline_log_writer_#{plugin}"

  # ── public API ────────────────────────────────────────────────────────────

  @spec start_run(String.t(), map) :: :ok
  def start_run(plugin, %{} = entry) when is_binary(plugin) do
    GenServer.cast(registered_name(plugin), {:start_run, entry})
  end

  @spec record_step(String.t(), map) :: :ok
  def record_step(plugin, %{} = entry) when is_binary(plugin) do
    GenServer.cast(registered_name(plugin), {:record_step, entry})
  end

  @spec finish_run(String.t(), String.t(), atom, String.t(), String.t() | nil) :: :ok
  def finish_run(plugin, run_id, status, finished_at, error)
      when is_binary(plugin) and is_binary(run_id) and is_atom(status) and is_binary(finished_at) do
    GenServer.call(
      registered_name(plugin),
      {:finish_run, run_id, status, finished_at, error}
    )
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(plugin) when is_binary(plugin), do: {:ok, plugin}

  @impl true
  def handle_cast({:start_run, entry}, plugin) do
    _ = Log.start_run(plugin, entry)
    {:noreply, plugin}
  end

  @impl true
  def handle_cast({:record_step, entry}, plugin) do
    _ = Log.record_step(plugin, entry)
    {:noreply, plugin}
  end

  @impl true
  def handle_call({:finish_run, run_id, status, finished_at, error}, _from, plugin) do
    _ = Log.finish_run(plugin, run_id, status, finished_at, error)
    {:reply, :ok, plugin}
  end
end

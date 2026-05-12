defmodule Sark.Plugin.Watcher do
  @moduledoc """
  Per-plugin file watcher. When `queries.yml`, included query files, or
  `metadata.yml` change, re-runs `Loader.load!/1` and
  `Registration.register_plugin!/1` so MCP tools pick up edits without a
  process restart.

  Migrations are NOT re-run — those are append-only and apply on cold
  boot only. Edits inside `migrations/` are ignored, as are DB files
  (`*.db`, `*.db-shm`, `*.db-wal`) and anything under `.git/`.

  Events are debounced by `@debounce_ms` so a burst of saves (editor
  swap-files, multi-file edits) collapses into a single reload.
  """

  use GenServer
  require Logger

  alias Sark.MCP.Registration
  alias Sark.Plugin.Loader
  alias Sark.Worker.Scheduler

  @debounce_ms 200

  @type opts :: [plugin_name: String.t(), plugin_dir: String.t()]

  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: registered_name(opts[:plugin_name]))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin_name), do: :"sark_watcher_#{plugin_name}"

  @impl true
  def init(opts) do
    plugin_name = Keyword.fetch!(opts, :plugin_name)
    plugin_dir = Keyword.fetch!(opts, :plugin_dir)

    {:ok, fs} = FileSystem.start_link(dirs: [plugin_dir])
    FileSystem.subscribe(fs)

    Logger.info("plugin #{plugin_name} watcher started — dir=#{plugin_dir}")

    {:ok,
     %{
       plugin_name: plugin_name,
       plugin_dir: plugin_dir,
       fs: fs,
       timer: nil
     }}
  end

  @impl true
  def handle_info({:file_event, fs, {path, _events}}, %{fs: fs} = state) do
    if reload_relevant?(path) do
      timer = restart_timer(state.timer)
      {:noreply, %{state | timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, fs, :stop}, %{fs: fs} = state) do
    Logger.warning("plugin #{state.plugin_name} watcher: file_system stopped")
    {:noreply, state}
  end

  def handle_info(:reload, state) do
    Logger.info("plugin #{state.plugin_name} hot-reload")

    try do
      spec = Loader.load!(state.plugin_name, state.plugin_dir)
      Registration.register_plugin!(spec)
      Scheduler.update_spec(state.plugin_name, spec)
    rescue
      e ->
        Logger.error(
          "plugin #{state.plugin_name} hot-reload failed: #{Exception.message(e)} — keeping previous registration"
        )
    end

    {:noreply, %{state | timer: nil}}
  end

  defp restart_timer(nil), do: Process.send_after(self(), :reload, @debounce_ms)

  defp restart_timer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), :reload, @debounce_ms)
  end

  defp reload_relevant?(path) do
    cond do
      String.contains?(path, "/.git/") -> false
      String.contains?(path, "/migrations/") -> false
      String.ends_with?(path, ".db") -> false
      String.ends_with?(path, ".db-shm") -> false
      String.ends_with?(path, ".db-wal") -> false
      String.ends_with?(path, ".yml") -> true
      String.ends_with?(path, ".yaml") -> true
      true -> false
    end
  end
end

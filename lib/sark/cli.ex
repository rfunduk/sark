defmodule Sark.CLI do
  @moduledoc """
  Manual worker-trigger helpers, callable against a running node.

  Config resolution is not handled here — the app boots from
  `SARK_CONFIG` (see `Sark.Boot`). These functions assume the
  application is already running.

  `run_worker/1` is the fire-and-forget manual trigger — invoke against
  a live release node via `bin/sark rpc 'Sark.CLI.run_worker("jot.dreamer")'`.
  It resolves `<plugin>.<worker>` from the live registry and spawns one
  run under the worker task supervisor. The dev `mix sark.worker` task
  shares `resolve_worker!/1`.
  """

  alias Sark.MCP.Internal
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker

  @doc """
  Fire-and-forget manual worker run against the already-running app.
  `target` is `"<plugin>.<worker>"`. Resolves the worker synchronously
  (so a bad target errors immediately at the `rpc` call site), then
  spawns the run under `Sark.Worker.TaskSup` and returns right away —
  the run outlives the `rpc` caller. Watch progress in the logs;
  terminal state lands in `_worker_log`.

  Intended for `bin/sark rpc 'Sark.CLI.run_worker("kb.dreamer")'`.
  """
  def run_worker(target) when is_binary(target) do
    {spec, worker} = resolve_worker!(target)

    {:ok, _pid} =
      Task.Supervisor.start_child(Sark.Worker.TaskSup, fn ->
        Sark.Worker.Runner.run(
          plugin: spec.name,
          worker: worker,
          spec: spec,
          llm: Sark.Worker.LLM.Anthropix
        )
      end)

    {:triggered, "#{spec.name}.#{worker.name}"}
  end

  @doc """
  Resolve `"<plugin>.<worker>"` against the live registry. Raises with
  a clear message on a bad target / unknown plugin / unknown worker.
  Shared by `run_worker/1` and the `mix sark.worker` task.
  """
  @spec resolve_worker!(String.t()) :: {Spec.t(), Worker.t()}
  def resolve_worker!(target) when is_binary(target) do
    {plugin_name, worker_name} = parse_target!(target)

    %Spec{} = spec = Internal.spec!(plugin_name)

    %Worker{} =
      worker =
      Enum.find(spec.workers || [], fn w -> w.name == String.to_atom(worker_name) end) ||
        raise ArgumentError,
              "worker `#{worker_name}` not found in plugin `#{plugin_name}`"

    {spec, worker}
  end

  defp parse_target!(target) do
    case String.split(target, ".", parts: 2) do
      [plugin, worker] when plugin != "" and worker != "" ->
        {plugin, worker}

      _ ->
        raise ArgumentError, "invalid target `#{target}` — expected `<plugin>.<worker>`"
    end
  end
end

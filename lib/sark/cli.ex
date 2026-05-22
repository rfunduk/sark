defmodule Sark.CLI do
  @moduledoc """
  Manual pipeline-trigger helpers, callable against a running node.

  Config resolution is not handled here — the app boots from
  `SARK_CONFIG` (see `Sark.Boot`). These functions assume the
  application is already running.

  `run_pipeline/1` is the fire-and-forget manual trigger — invoke
  against a live release node via
  `bin/sark rpc 'Sark.CLI.run_pipeline("kb.dreamer")'`. It resolves
  `<plugin>.<pipeline>` from the live registry, acquires the per-pipeline
  lock, and spawns one run under the pipeline task supervisor. The dev
  `mix sark.pipeline` task shares `resolve_pipeline!/1`.
  """

  alias Sark.MCP.Internal
  alias Sark.Pipeline.Lock
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec

  @doc """
  Fire-and-forget manual pipeline run against the already-running app.
  `target` is `"<plugin>.<pipeline>"`. Resolves the pipeline synchronously
  (so a bad target errors immediately at the `rpc` call site), then
  asks `Sark.Pipeline.Lock` for the slot. On success the run is spawned
  under `Sark.Pipeline.TaskSup` and the call returns right away — the
  run outlives the `rpc` caller. Watch progress in the logs; terminal
  state lands in `_pipeline_log` + `_pipeline_step_log`.

  Returns `{:triggered, "<plugin>.<pipeline>", run_id}` on success,
  `{:busy, "<plugin>.<pipeline>", existing_run_id}` if a run is already
  in flight.

  Intended for `bin/sark rpc 'Sark.CLI.run_pipeline("kb.dreamer")'`.
  """
  def run_pipeline(target) when is_binary(target) do
    {spec, pipeline} = resolve_pipeline!(target)

    case Lock.acquire(spec.name, pipeline.name) do
      {:busy, existing} ->
        {:busy, "#{spec.name}.#{pipeline.name}", existing}

      {:ok, run_id} ->
        {:ok, pid} =
          Task.Supervisor.start_child(
            Sark.Pipeline.TaskSup,
            fn ->
              try do
                Sark.Pipeline.Watcher.run(
                  plugin: spec.name,
                  pipeline: pipeline,
                  spec: spec,
                  run_id: run_id,
                  llm: Sark.LLM.Anthropix,
                  triggered_by: :manual
                )
              after
                Lock.release(spec.name, pipeline.name)
              end
            end,
            restart: :temporary
          )

        Lock.register_run(spec.name, pipeline.name, pid)

        {:triggered, "#{spec.name}.#{pipeline.name}", run_id}
    end
  end

  @doc """
  Resolve `"<plugin>.<pipeline>"` against the live registry. Raises
  with a clear message on a bad target / unknown plugin / unknown
  pipeline. Shared by `run_pipeline/1` and the `mix sark.pipeline` task.
  """
  @spec resolve_pipeline!(String.t()) :: {Spec.t(), Pipeline.t()}
  def resolve_pipeline!(target) when is_binary(target) do
    {plugin_name, pipeline_name} = parse_target!(target)

    %Spec{} = spec = Internal.spec!(plugin_name)

    %Pipeline{} =
      pipeline =
      Enum.find(spec.pipelines || [], fn p -> p.name == String.to_atom(pipeline_name) end) ||
        raise ArgumentError,
              "pipeline `#{pipeline_name}` not found in plugin `#{plugin_name}`"

    {spec, pipeline}
  end

  defp parse_target!(target) do
    case String.split(target, ".", parts: 2) do
      [plugin, pipeline] when plugin != "" and pipeline != "" ->
        {plugin, pipeline}

      _ ->
        raise ArgumentError, "invalid target `#{target}` — expected `<plugin>.<pipeline>`"
    end
  end
end

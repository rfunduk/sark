defmodule Sark.CLI do
  @moduledoc """
  Shared boot logic for both the release entrypoint (`sark --config …`)
  and the dev mix task (`mix sark --config …`).

  `main/1` is the release entrypoint: parses argv, fails hard on bad
  input, blocks forever once the application is up. The mix task reuses
  `parse_args!/2` and `boot!/1` directly so dev and prod follow the same
  code path.

  `run_worker/1` is the one-shot manual worker trigger. It assumes the
  application is *already running* — invoke against a live release node
  via `bin/sark rpc 'Sark.CLI.run_worker("jot.dreamer")'`. It does not
  boot; it resolves `<plugin>.<worker>` from the live registry and runs
  one synchronous pass through `Sark.Worker.Runner`. The dev mix task
  (`mix sark.worker`) shares `resolve_worker!/1`.
  """

  alias Sark.MCP.Internal
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker

  @doc """
  Release entrypoint. Parses argv, boots, blocks.
  """
  def main(argv) do
    path = parse_args!(argv, &fail_release/1)
    boot!(path)
    Process.sleep(:infinity)
  end

  @doc """
  Parse `--config <path>` from argv. Calls `on_error` with a message
  string when the flag is missing or invalid; otherwise returns the
  string path.
  """
  def parse_args!(argv, on_error) when is_function(on_error, 1) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [config: :string],
        aliases: [c: :config]
      )

    cond do
      invalid != [] ->
        on_error.("sark: invalid args #{inspect(invalid)}")

      true ->
        case Keyword.get(opts, :config) do
          nil -> on_error.("sark: --config <path> required")
          path -> path
        end
    end
  end

  @doc """
  Load the config and start the application. Idempotent against an
  already-started app — re-puts the config in persistent_term either
  way so a re-call picks up file edits.
  """
  def boot!(path) when is_binary(path) do
    config = Sark.Config.load!(path)
    Sark.Boot.put(config)
    {:ok, _} = Application.ensure_all_started(:sark)
    :ok
  end

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

  defp fail_release(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end
end

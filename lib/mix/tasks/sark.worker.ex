defmodule Mix.Tasks.Sark.Worker do
  @shortdoc "Trigger a worker manually for experimentation."

  @moduledoc """
  Run one worker once and stream its transcript to stdout.

      mix sark.worker --config config.yml jot.dreamer
      mix sark.worker -c config.yml jot.dreamer

  The argument is `<plugin>.<worker>`. Boots the OTP application
  exactly like `mix sark`, looks up the named worker, dispatches it
  through `Sark.Worker.Runner` with the production Anthropic LLM
  client, and exits when the loop terminates.

  No scheduling — this task is the manual trigger. Cron + on_event
  triggers land later.
  """

  use Mix.Task

  alias Sark.MCP.Internal
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker
  alias Sark.Worker.Runner

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [config: :string],
        aliases: [c: :config]
      )

    if invalid != [], do: Mix.raise("sark.worker: invalid args #{inspect(invalid)}")

    config_path =
      Keyword.get(opts, :config) || Mix.raise("sark.worker: --config <path> required")

    target =
      case rest do
        [t] -> t
        [] -> Mix.raise("sark.worker: missing <plugin>.<worker>")
        _ -> Mix.raise("sark.worker: pass exactly one <plugin>.<worker>, got #{inspect(rest)}")
      end

    {plugin_name, worker_name} = parse_target!(target)

    Sark.CLI.boot!(config_path)

    %Spec{} = spec = Internal.spec!(plugin_name)

    %Worker{} =
      worker =
      Enum.find(spec.workers, fn w -> w.name == String.to_atom(worker_name) end) ||
        Mix.raise("worker `#{worker_name}` not found in plugin `#{plugin_name}`")

    Mix.shell().info(
      "running worker #{plugin_name}.#{worker_name} (model=#{worker.model}, max_turns=#{worker.max_turns})"
    )

    result =
      Runner.run(
        plugin: plugin_name,
        worker: worker,
        spec: spec,
        llm: Sark.Worker.LLM.Anthropix,
        on_event: &print_event/1
      )

    case result do
      {:ok, :skipped} ->
        Mix.shell().info("\n[skipped] when: gate returned no rows")

      {:ok, %{turns: turns, stop_reason: reason}} ->
        Mix.shell().info("\n[done] turns=#{turns} stop=#{inspect(reason)}")

      {:error, reason} ->
        Mix.shell().error("\n[abort] #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_target!(target) do
    case String.split(target, ".", parts: 2) do
      [plugin, worker] when plugin != "" and worker != "" ->
        {plugin, worker}

      _ ->
        Mix.raise("invalid target `#{target}` — expected `<plugin>.<worker>`")
    end
  end

  defp print_event({:turn_start, n}) do
    IO.puts("\n--- turn #{n} ---")
  end

  defp print_event({:assistant_text, text}) do
    IO.puts("[assistant] #{text}")
  end

  defp print_event({:tool_call, %{id: id, name: name, input: input}}) do
    IO.puts("[tool_call ##{id}] #{name}(#{Jason.encode!(input)})")
  end

  defp print_event({:tool_result, %{id: id, ok: ok, text: text}}) do
    status = if ok, do: "ok", else: "ERR"
    preview = text |> String.slice(0, 200)

    suffix =
      if String.length(text) > 200 do
        " … (#{String.length(text) - 200} more chars)"
      else
        ""
      end

    IO.puts("[tool_result ##{id} #{status}] #{preview}#{suffix}")
  end

  defp print_event({:stop, %{reason: r, turns: t}}) do
    IO.puts("\n[stop] reason=#{inspect(r)} turns=#{t}")
  end

  defp print_event({:abort, %{reason: r, turns: t}}) do
    IO.puts("\n[abort] reason=#{inspect(r)} turns=#{t}")
  end

  defp print_event({:skipped, %{reason: r}}) do
    IO.puts("[skipped] #{inspect(r)}")
  end

  defp print_event({:loaded, %{rows: n}}) do
    IO.puts("[loaded] rows=#{n}")
  end
end

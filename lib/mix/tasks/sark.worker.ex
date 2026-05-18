defmodule Mix.Tasks.Sark.Worker do
  @shortdoc "Trigger a worker manually for experimentation."

  @moduledoc """
  Run one worker once and stream its transcript to stdout.

      SARK_CONFIG=config.yml mix sark.worker jot.dreamer

  The argument is `<plugin>.<worker>`. Boots the OTP application
  exactly like `mix sark` (config via `SARK_CONFIG`), looks up the
  named worker, dispatches it through `Sark.Worker.Runner` with the
  production Anthropic LLM client, and exits when the loop terminates.

  This is the source-tree dev trigger and runs the worker inline,
  streaming the transcript. For a running container use the
  fire-and-forget `Sark.CLI.run_worker/1` via `bin/sark rpc`.
  """

  use Mix.Task

  alias Sark.Worker.Runner

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    target =
      case argv do
        [t] -> t
        [] -> Mix.raise("sark.worker: missing <plugin>.<worker>")
        _ -> Mix.raise("sark.worker: pass exactly one <plugin>.<worker>, got #{inspect(argv)}")
      end

    {:ok, _} = Application.ensure_all_started(:sark)

    {spec, worker} =
      try do
        Sark.CLI.resolve_worker!(target)
      rescue
        e in ArgumentError -> Mix.raise("sark.worker: #{Exception.message(e)}")
      end

    Mix.shell().info(
      "running worker #{spec.name}.#{worker.name} (model=#{worker.model}, max_turns=#{worker.max_turns})"
    )

    result =
      Runner.run(
        plugin: spec.name,
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

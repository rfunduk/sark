defmodule Mix.Tasks.Sark.Pipeline do
  @shortdoc "Trigger a pipeline manually for experimentation."

  @moduledoc """
  Run one pipeline once and stream its transcript to stdout.

      SARK_CONFIG=config.yml mix sark.pipeline kb.dreamer

  The argument is `<plugin>.<pipeline>`. Boots the OTP application
  exactly like `mix sark` (config via `SARK_CONFIG`), looks up the
  named pipeline, dispatches it through `Sark.Pipeline.Runner` with
  the production Anthropic LLM client, and exits when the run
  terminates.

  This is the source-tree dev trigger and runs the pipeline inline,
  streaming step events. For a running container use the
  fire-and-forget `Sark.CLI.run_pipeline/1` via `bin/sark rpc`.
  """

  use Mix.Task

  alias Sark.Pipeline.Lock
  alias Sark.Pipeline.Watcher

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    target =
      case argv do
        [t] ->
          t

        [] ->
          Mix.raise("sark.pipeline: missing <plugin>.<pipeline>")

        _ ->
          Mix.raise("sark.pipeline: pass exactly one <plugin>.<pipeline>, got #{inspect(argv)}")
      end

    {:ok, _} = Application.ensure_all_started(:sark)

    {spec, pipeline} =
      try do
        Sark.CLI.resolve_pipeline!(target)
      rescue
        e in ArgumentError -> Mix.raise("sark.pipeline: #{Exception.message(e)}")
      end

    run_id =
      case Lock.acquire(spec.name, pipeline.name) do
        {:ok, id} ->
          id

        {:busy, existing} ->
          Mix.raise(
            "sark.pipeline: #{spec.name}.#{pipeline.name} already running (run #{existing})"
          )
      end

    Lock.register_run(spec.name, pipeline.name, self())

    Mix.shell().info(
      "running pipeline #{spec.name}.#{pipeline.name} (run #{run_id}, steps=#{length(pipeline.steps)})"
    )

    result =
      try do
        Watcher.run(
          plugin: spec.name,
          pipeline: pipeline,
          spec: spec,
          run_id: run_id,
          llm: Sark.LLM.Anthropix,
          triggered_by: :manual,
          on_event: &print_event/1
        )
      after
        Lock.release(spec.name, pipeline.name)
      end

    case result do
      {:ok, :skipped} ->
        Mix.shell().info("\n[skipped] when: gate returned no rows")

      {:ok, %{run_id: rid}} ->
        Mix.shell().info("\n[done] run #{rid}")

      {:error, reason} ->
        Mix.shell().error("\n[abort] #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_event({:run_start, %{run_id: rid, pipeline: name}}) do
    IO.puts("\n--- pipeline #{name} run #{rid} ---")
  end

  defp print_event({:step_start, %{index: i, kind: k}}) do
    IO.puts("\n[step #{i} #{k}] start")
  end

  defp print_event({:step_ok, %{index: i, kind: k, bytes: bytes}}) do
    IO.puts("[step #{i} #{k}] ok (#{bytes} bytes)")
  end

  defp print_event({:step_fail, %{index: i, kind: k, error: err}}) do
    IO.puts("[step #{i} #{k}] FAIL — #{err}")
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

  defp print_event({:skipped, %{reason: r}}) do
    IO.puts("[skipped] #{inspect(r)}")
  end

  defp print_event({:run_ok, %{run_id: rid}}) do
    IO.puts("[run_ok] #{rid}")
  end

  defp print_event({:run_fail, %{run_id: rid, error: err}}) do
    IO.puts("[run_fail] #{rid} — #{err}")
  end

  defp print_event(_), do: :ok
end

defmodule Sark.CLI do
  @moduledoc """
  Shared boot logic for both the release entrypoint (`sark --config …`)
  and the dev mix task (`mix sark --config …`).

  `main/1` is the release entrypoint: parses argv, fails hard on bad
  input, blocks forever once the application is up. The mix task reuses
  `parse_args!/2` and `boot!/1` directly so dev and prod follow the same
  code path.
  """

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

  defp fail_release(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end
end
